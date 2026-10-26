import Darwin
import Foundation

/// Headless native Export All: `MacScope --export-native-pseudocode <binary> <output.txt>` loads
/// the binary like the other headless modes, runs the same native whole-image export as
/// File › Export All Pseudocode (Native) — built by `AllPseudocodeExportNativeCapture.makeOperation`
/// and published by `NativePseudocodeBatchExportOperation.publish` — and prints one JSON line:
/// `{"counts":{…},"report":…,"seconds":…,"text":…,"textSHA256":…}`. The screen-free acceptance
/// route for the native export. Exit 0 on success, 1 with a one-line stderr reason otherwise.
enum NativeExportCLI {
    static let flag = "--export-native-pseudocode"

    struct Request: Equatable {
        let binaryPath: String
        let outputPath: String
    }

    enum Refusal: LocalizedError, Equatable {
        case pathNotAbsolute(String)
        case outputParentMissing(String)
        case outputIsDirectory(String)

        var errorDescription: String? {
            switch self {
            case .pathNotAbsolute(let path): "The path must be absolute: \(path)"
            case .outputParentMissing(let path): "The output folder does not exist: \(path)"
            case .outputIsDirectory(let path): "The output path is a folder: \(path)"
            }
        }
    }

    struct Summary: Codable, Equatable {
        let text: String
        let report: String
        let counts: [String: Int]
        let textSHA256: String
        let seconds: Double
    }

    /// Parses `--export-native-pseudocode <binary> <output>` — but ONLY when the flag occupies the
    /// mode slot and is followed by exactly two values, as `CLIRunner.request(from:)` does.
    static func request(from arguments: [String]) -> Request? {
        guard arguments.dropFirst().first == flag, arguments.count == 4 else { return nil }
        return Request(binaryPath: arguments[2], outputPath: arguments[3])
    }

    /// Both paths absolute; the output's folder must exist. Returns canonical URLs.
    static func resolve(_ request: Request) throws -> (binary: URL, output: URL) {
        for path in [request.binaryPath, request.outputPath] where !path.hasPrefix("/") {
            throw Refusal.pathNotAbsolute(path)
        }
        guard let binary = MCPLauncher.canonicalURL(forPath: request.binaryPath),
              !request.outputPath.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw Refusal.pathNotAbsolute(request.binaryPath)
        }
        let output = URL(fileURLWithPath: request.outputPath).standardizedFileURL
        let parent = output.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw Refusal.outputParentMissing(parent.path) }
        if FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw Refusal.outputIsDirectory(output.path)
        }
        return (binary, output)
    }

    /// Runs the native export for `store`'s focused image and publishes text + report at
    /// `output`. Factored out of `run` so it is testable without a binary, a native runtime or
    /// exiting the process. Headless has one store and no window, so the owner fence is the
    /// store's document identity plus the bound binary's file identity.
    @MainActor
    static func export(
        store: WorkspaceStore,
        to output: URL,
        decompiler: any NativePseudocodeBatchDecompiling,
        nativeEnabled: Bool,
        validateIdentity: @escaping @MainActor () throws -> Void = {}
    ) async throws -> Summary {
        let started = ContinuousClock.now
        let op = try AllPseudocodeExportNativeCapture.makeOperation(
            store: store, nativeEnabled: nativeEnabled, ownerGeneration: UUID())
        let owner = op.owner
        let workspaceID = store.workspaceID
        let slot = op.context.imageSlot
        let isCurrent: @MainActor () -> Bool = { [weak store] in
            guard let store, !op.isCancelled, (try? validateIdentity()) != nil else { return false }
            return store.workspaceID == workspaceID && store.documentID == owner.documentID
                && store.mutationGeneration.rawValue == owner.documentGeneration
                && store.snapshot.binary(in: slot)?.id == owner.binaryID
        }
        let worker = Task.detached(priority: .userInitiated) {
            try await op.run(decompiler: decompiler, isCurrent: { await isCurrent() })
        }
        let result = try await worker.value
        try validateIdentity()
        guard isCurrent() else {
            op.cancel()
            throw NativePseudocodeBatchExportOperation.Failure.staleOwner
        }
        let reportURL = try op.publish(result, currentOwner: owner, to: output)
        let elapsed = ContinuousClock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return Summary(text: output.path, report: reportURL.path, counts: result.report.counts,
                       textSHA256: result.report.textSHA256, seconds: (seconds * 1000).rounded() / 1000)
    }

    static func encode(_ summary: Summary) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(summary)
    }

    /// The one-line reason printed on failure.
    static func describe(_ error: Error) -> String {
        if let refusal = error as? AllPseudocodeExportNativeCapture.Refusal { return refusal.message }
        return AllPseudocodeExportNativeCapture.describe(error)
    }

    /// Loads the binary, exports, prints the summary line, and exits. Called at program entry
    /// (main thread, no SwiftUI run loop); the async export runs under `dispatchMain`, as the
    /// headless MCP server does.
    @MainActor
    static func run(_ request: Request) -> Never {
        let protocolOutput: FileHandle
        do {
            protocolOutput = try HeadlessProtocolIO.isolateStandardOutput()
        } catch {
            fail(error)
        }
        Task { @MainActor in
            let summary: Summary
            do {
                let (binaryURL, outputURL) = try resolve(request)
                let nativeEnabled = NativeDecompilerRuntimeRegistry.isProductEnabled
                guard nativeEnabled else { throw AllPseudocodeExportNativeCapture.Refusal.nativeDisabled }
                let bound = try MCPLauncher.makeBoundStore(binaryURL: binaryURL)
                summary = try await export(
                    store: bound.store, to: outputURL,
                    decompiler: NativeDecompilerRuntimeRegistry.productionShared,
                    nativeEnabled: nativeEnabled,
                    validateIdentity: { try bound.validateIdentity() })
            } catch {
                try? protocolOutput.close()
                fail(error)
            }
            do {
                try HeadlessProtocolIO.writeLine(encode(summary), to: protocolOutput)
            } catch {
                try? protocolOutput.close()
                fail(error)
            }
            try? protocolOutput.close()
            exit(0)
        }
        dispatchMain()
    }

    private static func fail(_ error: Error) -> Never {
        let reason = NativePseudocodeBatchExport.singleLine(describe(error), limit: 1_000)
        FileHandle.standardError.write(Data("MacScope native export: \(reason)\n".utf8))
        exit(1)
    }
}
