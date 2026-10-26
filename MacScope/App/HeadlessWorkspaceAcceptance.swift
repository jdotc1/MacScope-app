import CryptoKit
import Darwin
import Foundation
import ServiceManagement

/// A reserved, non-scene process mode. Uses the production package/session/broker seams;
/// it neither constructs an App nor participates in system recent-document presentation.
@MainActor
enum HeadlessWorkspaceAcceptance {
    static let selector = "--headless-workspace-acceptance"

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    struct Request {
        let action: String
        let workspace: URL
        let output: URL
        let prompt: String?

        static func decode(_ data: Data) throws -> Request {
            guard case let .object(value) = try HeadlessJSON.decode(data, maximumBytes: 65_536),
                  Set(value.keys).isSubset(of: ["action", "workspace", "output", "prompt"]),
                  case let .string(action) = value["action"],
                  ["inspect", "terminal", "rea", "reopen", "annotation-transfer"].contains(action),
                  case let .string(workspace) = value["workspace"],
                  case let .string(output) = value["output"],
                  workspace.hasPrefix("/"), output.hasPrefix("/"),
                  !workspace.contains("\0"), !output.contains("\0"),
                  workspace.utf8.count < 4096, output.utf8.count < 4096 else {
                throw Failure(description: "invalid-headless-workspace-request")
            }
            let prompt: String?
            if case let .string(text) = value["prompt"], !text.isEmpty, text.utf8.count <= 16_384 {
                prompt = text
            } else {
                prompt = nil
            }
            guard (action == "rea") == (prompt != nil),
                  action == "rea" || value["prompt"] == nil else {
                throw Failure(description: "invalid-headless-workspace-prompt")
            }
            let source = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().standardizedFileURL
            let destination = URL(fileURLWithPath: output).resolvingSymlinksInPath().standardizedFileURL
            guard source.pathExtension == "mscope", source != destination,
                  !destination.path.hasPrefix(source.path + "/") else {
                throw Failure(description: "invalid-headless-workspace-paths")
            }
            return Request(action: action, workspace: source, output: destination, prompt: prompt)
        }
    }

    /// Malformed use of this reserved flag must exit, never fall through into SwiftUI.
    static func runIfRequested(arguments: [String]) -> Bool {
        guard arguments.dropFirst().contains(where: { $0.hasPrefix(selector) }) else { return false }
        guard arguments.count == 3, arguments[1] == selector,
              arguments[2].hasPrefix("/") else {
            fail("invalid-headless-workspace-arguments", code: EX_USAGE)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1200) {
            FileHandle.standardError.write(Data("headless-workspace-process-deadline\n".utf8))
            Darwin.exit(EX_TEMPFAIL)
        }
        Task { @MainActor in
            do {
                let request = try Request.decode(CLIRunner.loadScript(
                    at: URL(fileURLWithPath: arguments[2]), maximumBytes: 65_536
                ))
                let result = try await execute(request)
                try FileHandle.standardOutput.write(contentsOf: result.jsonData())
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                fail(String(describing: error), code: EX_SOFTWARE)
            }
        }
        dispatchMain()
    }

    static func execute(_ request: Request) async throws -> ScriptValue {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: request.output.path) else {
            throw Failure(description: "headless-output-must-be-new")
        }
        try manager.createDirectory(at: request.output, withIntermediateDirectories: false)
        let mutates = request.action == "terminal" || request.action == "rea"
            || request.action == "annotation-transfer"
        let workspace = mutates
            ? request.output.appendingPathComponent(request.workspace.lastPathComponent)
            : request.workspace
        let registry = WorkspaceSessionRegistry()
        let started = ContinuousClock.now
        let recents = NonPresentingRecents()
        var report: [String: ScriptValue] = [
            "action": .string(request.action), "workspace": .string(workspace.path),
            "sourceWorkspace": .string(request.workspace.path),
            "pid": .int(Int64(ProcessInfo.processInfo.processIdentifier)),
            "executable": .string(Bundle.main.executableURL?.path ?? "unknown"),
            "evidenceScope": .string("headless production operations; no renderer, visible controls, or Open Recent acceptance")
        ]
        func emit(_ passed: Bool, error: String? = nil) throws -> ScriptValue {
            report["passed"] = .bool(passed)
            report["error"] = error.map(ScriptValue.string) ?? .null
            report["elapsed"] = .string(String(describing: started.duration(to: .now)))
            let result = ScriptValue.object(report)
            try result.jsonData().write(to: request.output.appendingPathComponent("result.json"), options: .atomic)
            return result
        }
        do {
            // Terminal acceptance uses the already-enabled installed LaunchAgent. This mode
            // does not register services or ask macOS to present an approval interface.
            if request.action == "terminal" {
                guard SMAppService.agent(plistName: Phase2ShellBrokerLaunchAgentRegistration.plistName).status == .enabled else {
                    throw Failure(description: "persistent-shell-broker-not-enabled")
                }
            }
            if mutates { try manager.copyItem(at: request.workspace, to: workspace) }
            let coordinator = WorkspaceOpenCoordinator(
                registry: registry, io: WorkspaceDocumentIO(),
                windowActivator: NonPresentingActivator(),
                storeFactory: {
                    let store = WorkspaceStore(
                        workspaceName: "Headless acceptance",
                        snapshot: WorkspaceSnapshot(binaries: [], analysisBySlot: [:]),
                        engine: AnalysisEngine(), autosaveScheduler: nil,
                        phase2ShellSessionClient: Phase2HumanPTYShellSessionClient(
                            transport: NSXPCShellBrokerTransport(endpoint: .persistentLaunchAgent)
                        ),
                        phase2ShellBrokerEndpoint: .persistentLaunchAgent
                    )
                    store.recents = recents
                    return store
                }
            )
            let disposition = await coordinator.open(.init(
                url: workspace, source: .automation, preferredReusableWindow: nil
            ))
            guard case let .openedWindow(id) = disposition,
                  let store = registry.storeIfPresent(for: id),
                  let session = registry.documentSessionIfPresent(for: id) else {
                throw Failure(description: "headless-open-rejected: \(disposition)")
            }
            report["before"] = try state(store)
            switch request.action {
            case "terminal":
                report["operation"] = try await HeadlessWorkspaceTerminalAcceptance.run(
                    store: store, artifactRoot: request.output
                )
            case "rea":
                report["operation"] = try await HeadlessWorkspaceREAAcceptance.run(
                    store: store, prompt: request.prompt!, artifactRoot: request.output
                )
            case "annotation-transfer":
                // RX-01 §2.8: preview → high-confidence selection → commit → Undo/Redo → save
                // and reload through the document session → compare authoring digests.
                let operation = try await HeadlessWorkspaceAnnotationTransferAcceptance.run(
                    store: store,
                    save: { _ in
                        let saved = await session.save()
                        guard case .saved(clean: true, adopted: _) = saved else {
                            throw Failure(description: "headless-save-failed: \(saved)")
                        }
                        // Reopen through the same document authority: a validated read of the
                        // saved package installed into this store.
                        if case let .failure(error) = await session.reloadFromDisk() {
                            throw Failure(description: "headless-reopen-failed: \(error)")
                        }
                        return (workspace, store.snapshot)
                    }
                )
                report["operation"] = operation
                guard case let .object(fields) = operation, fields["passed"] == .bool(true) else {
                    throw Failure(description: "annotation-transfer-acceptance-failed")
                }
            default: break
            }
            if mutates {
                let saved = await session.save()
                guard case .saved(clean: true, adopted: _) = saved else {
                    throw Failure(description: "headless-save-failed: \(saved)")
                }
                report["savedClean"] = .bool(true)
            }
            report["after"] = try state(store)
            guard await registry.shutdown() else {
                throw Failure(description: "headless-shutdown-rejected")
            }
            // Retain the reservation coordinator until session shutdown has completed.
            withExtendedLifetime(coordinator) {}
            return try emit(true)
        } catch {
            _ = await registry.shutdown()
            _ = try? emit(false, error: String(describing: error))
            throw error
        }
    }

    private static func state(_ store: WorkspaceStore) throws -> ScriptValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let shellData = try encoder.encode(store.phase2ShellSession.packagePhase2ShellSession)
        return .object([
            "authoringDigestBySlot": HeadlessWorkspaceAnnotationTransferAcceptance.scriptValue(
                HeadlessWorkspaceAnnotationTransferAcceptance.authoringDigestBySlot(store.snapshot)
            ),
            "documentID": .string(store.documentID.uuidString),
            "workspaceID": .string(store.workspaceID.uuidString),
            "shellState": .string(String(describing: store.phase2ShellSession.snapshot?.state)),
            "hasDurableShellIdentity": .bool(store.phase2ShellSession.durableRecoveryIdentity != nil),
            "persistedShellSHA256": .string(SHA256.hash(data: shellData).map { String(format: "%02x", $0) }.joined()),
            "assistantRecords": .array(store.phase2AssistantSessionHistory.map { record in
                .object([
                    "id": .string(record.id.uuidString),
                    "status": .string(String(describing: record.status)),
                    "contentSHA256": .string(record.contentSHA256),
                    "answer": record.answerText.map(ScriptValue.string) ?? .null
                ])
            })
        ])
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data(("MacScope headless acceptance: " + message + "\n").utf8))
        Darwin.exit(code)
    }

    private final class NonPresentingActivator: WorkspaceWindowActivating {
        func activateWindow(_ windowID: WorkspaceWindowID) -> Bool { false }
    }

    private final class NonPresentingRecents: WorkspaceRecentsRecording {
        private(set) var recentDocumentURLs: [URL] = []
        func noteRecentDocument(_ url: URL) { recentDocumentURLs.append(url) }
        func clearRecentDocuments() { recentDocumentURLs.removeAll() }
    }
}
