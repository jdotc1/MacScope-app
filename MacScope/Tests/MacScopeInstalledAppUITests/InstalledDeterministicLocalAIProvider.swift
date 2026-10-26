import Darwin
import Foundation
import XCTest

/// Test-owned, literal-loopback provider for installed qualification. It never launches an external
/// model application, never binds a non-loopback interface, and records only bounded request shape
/// plus body digests.
final class InstalledDeterministicLocalAIProvider: @unchecked Sendable {
    enum Route: String, CaseIterable {
        case chat = "chat"
        case discovery = "discovery"
        case load = "load"
        case unload = "unload"
    }

    struct RequestSummary: Decodable, Equatable {
        let bodyBytes: Int
        let bodySHA256: String
        let method: String
        let path: String
        let sequence: Int

        private enum CodingKeys: String, CodingKey {
            case bodyBytes = "body_bytes"
            case bodySHA256 = "body_sha256"
            case method, path, sequence
        }
    }

    private struct SummaryDocument: Decodable {
        let requests: [RequestSummary]
    }

    let endpointOrigin: String
    let ownedPID: Int32
    private let controlRoot: URL
    private let process: Process
    private let rootURL: URL
    private let summaryURL: URL

    private static let maximumStartupDiagnosticBytes = 16 * 1_024
    private static let startupDiagnosticName = "provider-startup.log"

    private init(
        endpointOrigin: String,
        process: Process,
        rootURL: URL,
        controlRoot: URL,
        summaryURL: URL
    ) {
        self.endpointOrigin = endpointOrigin
        self.process = process
        ownedPID = process.processIdentifier
        self.rootURL = rootURL
        self.controlRoot = controlRoot
        self.summaryURL = summaryURL
    }

    static func start(
        oracle: Task10InstalledScenarioFixtureCatalog.ProviderOracle,
        timeout: TimeInterval = 5
    ) throws -> Self {
        let manager = FileManager.default
        let rootURL = manager.temporaryDirectory.appendingPathComponent(
            "MacScope-Task10-Loopback-\(UUID().uuidString)",
            isDirectory: true
        )
        let controlRoot = rootURL.appendingPathComponent("control", isDirectory: true)
        try manager.createDirectory(at: controlRoot, withIntermediateDirectories: true)
        let scriptURL = rootURL.appendingPathComponent("owned_provider.py")
        let portURL = rootURL.appendingPathComponent("port.json")
        let summaryURL = rootURL.appendingPathComponent("request-summary.json")
        let diagnosticLogURL = rootURL.appendingPathComponent(startupDiagnosticName)
        try Data(pythonProvider.utf8).write(to: scriptURL, options: .atomic)
        guard manager.createFile(
            atPath: diagnosticLogURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw fixtureError("The loopback provider diagnostic log could not be created.")
        }
        let diagnosticLog = try FileHandle(forWritingTo: diagnosticLogURL)

        let process = Process()
        process.executableURL = try xcodePythonExecutable()
        process.arguments = [
            "-B",
            scriptURL.path,
            rootURL.path,
            oracle.modelKey,
            oracle.displayName,
            oracle.publisher,
            oracle.instanceID,
        ]
        process.environment = [
            "LANG": "C.UTF-8",
            "PATH": "/usr/bin:/bin",
            "PYTHONDONTWRITEBYTECODE": "1",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = diagnosticLog
        process.standardError = diagnosticLog
        do {
            try process.run()
        } catch {
            try? diagnosticLog.close()
            let detail = boundedStartupDiagnostics(at: diagnosticLogURL)
            throw fixtureError(
                startupFailureDescription(
                    reason: "launch failed: \(error.localizedDescription)",
                    diagnosticLogURL: diagnosticLogURL,
                    detail: detail
                )
            )
        }
        let ownedPID = process.processIdentifier
        guard ownedPID > 1 else {
            stopExactOwnedProcess(process, ownedPID: ownedPID)
            try? diagnosticLog.close()
            let detail = boundedStartupDiagnostics(at: diagnosticLogURL)
            throw fixtureError(
                startupFailureDescription(
                    reason: "the child did not expose an owned PID",
                    diagnosticLogURL: diagnosticLogURL,
                    detail: detail
                )
            )
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: portURL),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let port = object["port"] as? Int,
               (1...65_535).contains(port) {
                try? diagnosticLog.close()
                return Self(
                    endpointOrigin: "http://127.0.0.1:\(port)",
                    process: process,
                    rootURL: rootURL,
                    controlRoot: controlRoot,
                    summaryURL: summaryURL
                )
            }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        stopExactOwnedProcess(process, ownedPID: ownedPID)
        try? diagnosticLog.close()
        let termination = process.terminationReason == .exit ? "exit" : "signal"
        let detail = boundedStartupDiagnostics(at: diagnosticLogURL)
        throw fixtureError(
            startupFailureDescription(
                reason: "the child ended by \(termination) with status \(process.terminationStatus) before binding 127.0.0.1:0",
                diagnosticLogURL: diagnosticLogURL,
                detail: detail
            )
        )
    }

    func hold(_ route: Route) throws {
        try Data().write(to: holdURL(route), options: .atomic)
    }

    func release(_ route: Route) throws {
        let url = holdURL(route)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func setAvailable(_ available: Bool) throws {
        let url = controlRoot.appendingPathComponent("unavailable")
        if available {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } else {
            try Data().write(to: url, options: .atomic)
        }
    }

    func requestSummary() throws -> [RequestSummary] {
        guard FileManager.default.fileExists(atPath: summaryURL.path) else { return [] }
        return try JSONDecoder().decode(
            SummaryDocument.self,
            from: Data(contentsOf: summaryURL)
        ).requests
    }

    @discardableResult
    func waitForRequest(
        path: String,
        minimumCount: Int = 1,
        timeout: TimeInterval = 5
    ) throws -> [RequestSummary] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let summary = try requestSummary()
            if summary.filter({ $0.path == path }).count >= minimumCount { return summary }
            guard process.isRunning, process.processIdentifier == ownedPID else {
                throw Self.fixtureError("The exact loopback provider PID exited unexpectedly.")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw Self.fixtureError("Timed out waiting for the deterministic request: \(path)")
    }

    func stopExactOwnedProcessIfNeeded() {
        Self.stopExactOwnedProcess(process, ownedPID: ownedPID)
        XCTAssertFalse(process.isRunning, "the exact test-owned provider PID must be reaped")
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func holdURL(_ route: Route) -> URL {
        controlRoot.appendingPathComponent("hold-\(route.rawValue)")
    }

    private static func stopExactOwnedProcess(_ process: Process, ownedPID: Int32) {
        guard ownedPID > 1, process.processIdentifier == ownedPID else { return }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    private static func fixtureError(_ message: String) -> NSError {
        NSError(
            domain: "MacScopeInstalledAppUITests.OwnedLoopbackProvider",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    /// `/usr/bin/python3` is an xcrun-backed selector on current macOS and xcrun refuses to run
    /// inside the sandboxed XCUITest host. Resolve the already-loaded Xcode developer directory
    /// instead, then execute that Xcode's Python binary directly. This keeps the provider owned by
    /// the test runner and avoids consulting another Xcode installation or the network.
    private static func xcodePythonExecutable() throws -> URL {
        let developerMarker = "/Contents/Developer/"
        var loadedPaths = Bundle.allFrameworks.map(\.bundleURL.path)
        if let frameworkPaths = ProcessInfo.processInfo.environment["DYLD_FRAMEWORK_PATH"] {
            loadedPaths.append(
                contentsOf: frameworkPaths.split(separator: ":").map(String.init)
            )
        }

        let developerRoots = Set(loadedPaths.compactMap { path -> String? in
            guard let marker = path.range(of: developerMarker) else { return nil }
            return String(path[..<marker.upperBound])
        })
        let manager = FileManager.default
        let relativePythonPath =
            "Library/Frameworks/Python3.framework/Versions/Current/Resources/"
            + "Python.app/Contents/MacOS/Python"
        let candidates = developerRoots.sorted().compactMap { developerRoot -> URL? in
            let root = URL(fileURLWithPath: developerRoot, isDirectory: true)
                .standardizedFileURL
            let candidate = root.appendingPathComponent(relativePythonPath)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard candidate.path.hasPrefix(root.path + "/"),
                  manager.isExecutableFile(atPath: candidate.path) else {
                return nil
            }
            return candidate
        }
        guard candidates.count == 1, let executable = candidates.first else {
            throw fixtureError(
                "The sandboxed loopback provider could not resolve exactly one executable "
                    + "Python runtime from the loaded Xcode developer directory."
            )
        }
        return executable
    }

    private static func boundedStartupDiagnostics(at url: URL) -> String {
        let truncationMarker = Data("\n[diagnostics truncated]\n".utf8)
        let payloadLimit = maximumStartupDiagnosticBytes - truncationMarker.count
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "<diagnostic log unavailable>"
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: payloadLimit + 1) else {
            return "<diagnostic log unreadable>"
        }

        var bounded = Data(data.prefix(payloadLimit))
        if data.count > payloadLimit {
            bounded.append(truncationMarker)
        }
        try? bounded.write(to: url, options: .atomic)

        let text = String(decoding: bounded, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "<no child output>" : text
    }

    private static func startupFailureDescription(
        reason: String,
        diagnosticLogURL: URL,
        detail: String
    ) -> String {
        "The loopback provider startup failed because \(reason). "
            + "Bounded diagnostics were preserved at \(diagnosticLogURL.path): \(detail)"
    }

    private static let pythonProvider = #"""
import hashlib
import http.server
import json
import os
import pathlib
import sys
import tempfile
import time

root = pathlib.Path(sys.argv[1])
model_key, display_name, publisher, instance_id = sys.argv[2:6]
control_root = root / "control"
port_path = root / "port.json"
summary_path = root / "request-summary.json"
requests = []
loaded = False

def atomic_json(path, value):
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True, separators=(",", ":"))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def route_name(path):
    return {
        "/api/v1/models": "discovery",
        "/api/v1/models/load": "load",
        "/api/v1/models/unload": "unload",
        "/v1/chat/completions": "chat",
    }.get(path, "unknown")

def record(method, path, body):
    requests.append({
        "body_bytes": len(body),
        "body_sha256": hashlib.sha256(body).hexdigest(),
        "method": method,
        "path": path,
        "sequence": len(requests) + 1,
    })
    atomic_json(summary_path, {"requests": requests})

def wait_if_held(path):
    hold = control_root / ("hold-" + route_name(path))
    while hold.exists():
        time.sleep(0.01)

def model_catalog():
    instances = []
    if loaded:
        instances.append({
            "id": instance_id,
            "config": {"context_length": 4096},
        })
    return {"models": [{
        "type": "llm",
        "publisher": publisher,
        "key": model_key,
        "display_name": display_name,
        "quantization": None,
        "size_bytes": 1,
        "params_string": None,
        "loaded_instances": instances,
        "max_context_length": 4096,
        "format": "gguf",
    }]}

def chat_reply(body):
    model = body.get("model", model_key)
    request_value = {}
    messages = body.get("messages", [])
    if len(messages) > 1 and isinstance(messages[1].get("content"), str):
        try:
            request_value = json.loads(messages[1]["content"])
        except (TypeError, ValueError):
            request_value = {}
    if "jobID" in request_value and "roundID" in request_value and body.get("tools"):
        handles = request_value.get("handles", [])
        selected = [handles[0]["handleID"]] if handles else []
        content = {
            "job_id": request_value["jobID"],
            "checkpoint_revision": request_value.get("checkpointRevision", 0),
            "round_id": request_value["roundID"],
            "selected_handle_ids": selected,
            "disposition": "sufficientEvidence",
            "unresolved_gaps": [],
            "resolved_gaps": [],
        }
    elif "jobID" in request_value:
        content = {
            "kind": "insufficientEvidence",
            "text": "No accepted reconstruction evidence was supplied.",
            "evidence_ids": [],
        }
    else:
        content = {
            "kind": "insufficient_evidence",
            "text": "",
            "evidence_ids": [],
            "reason": "No grounded evidence was supplied.",
        }
    return {
        "id": "task10-installed-loopback",
        "object": "chat.completion",
        "created": 1,
        "model": model,
        "choices": [{"index": 0, "message": {
            "role": "assistant",
            "content": json.dumps(content, sort_keys=True, separators=(",", ":")),
        }}],
        "usage": {"prompt_tokens": 11, "completion_tokens": 5, "total_tokens": 16},
    }

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def read_body(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length < 0 or length > 1048576:
            raise ValueError("body limit")
        return self.rfile.read(length)

    def respond(self, status, value):
        payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.wfile.flush()

    def dispatch(self, method):
        global loaded
        try:
            body_bytes = self.read_body() if method == "POST" else b""
            record(method, self.path, body_bytes)
            wait_if_held(self.path)
            if (control_root / "unavailable").exists():
                self.respond(503, {"error": "provider unavailable"})
                return
            body = json.loads(body_bytes.decode("utf-8")) if body_bytes else {}
            if method == "GET" and self.path == "/api/v1/models":
                self.respond(200, model_catalog())
            elif method == "POST" and self.path == "/api/v1/models/load":
                loaded = True
                self.respond(200, {
                    "type": "llm",
                    "instance_id": instance_id,
                    "load_time_seconds": 0.01,
                    "status": "loaded",
                    "load_config": {"context_length": body.get("context_length", 4096)},
                })
            elif method == "POST" and self.path == "/api/v1/models/unload":
                loaded = False
                self.respond(200, {"instance_id": body.get("instance_id", instance_id)})
            elif method == "POST" and self.path == "/v1/chat/completions":
                self.respond(200, chat_reply(body))
            else:
                self.respond(404, {"error": "unknown route"})
        except (UnicodeDecodeError, ValueError, json.JSONDecodeError):
            self.respond(400, {"error": "invalid request"})

    def do_GET(self):
        self.dispatch("GET")

    def do_POST(self):
        self.dispatch("POST")

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
atomic_json(port_path, {"port": server.server_address[1]})
atomic_json(summary_path, {"requests": []})
server.serve_forever(poll_interval=0.05)
"""#
}
