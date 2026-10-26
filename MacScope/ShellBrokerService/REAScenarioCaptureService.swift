import Foundation
import Darwin
import Security
#if TESTING_SHELL_BROKER_PRINCIPAL
@testable import MacScope
#endif

/// Runs only inside the authenticated ShellBroker XPC connection, using its existing lease.
final class REAScenarioCaptureService: @unchecked Sendable {
#if TESTING_SHELL_BROKER_PRINCIPAL
    private typealias CaptureTerminal = MacScope.Phase2SourceExecutionTerminal
    private typealias CaptureCleanup = MacScope.Phase2SourceExecutionCleanup
#else
    private typealias CaptureTerminal = Phase2SourceExecutionTerminal
    private typealias CaptureCleanup = Phase2SourceExecutionCleanup
#endif
    private final class Operation: @unchecked Sendable {
        let request: REAScenarioCaptureRequest; let bytes: Data
        var cancelled = false; var started = false; var replies: [(Data) -> Void] = []
        init(_ request: REAScenarioCaptureRequest, _ bytes: Data) { self.request = request; self.bytes = bytes }
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "org.macscope.app.rea-capture")
    private var active: Operation?
    private var invalidated = false
    private var seen = Set<UUID>()
    private var cached: [UUID: (Data, Data)] = [:]
    private let adapter = Phase2ShellBrokerProcessAdapter()
    func execute(_ bytes: Data, reply: @escaping (Data) -> Void) { submit(bytes, cancel: false, reply: reply) }
    func cancel(_ bytes: Data, reply: @escaping (Data) -> Void) { submit(bytes, cancel: true, reply: reply) }
    func invalidate() {
        let pending = lock.withLock { () -> Operation? in
            invalidated = true; active?.cancelled = true
            guard let operation = active, !operation.started else { return nil }
            active = nil; return operation
        }
        if let pending { let data = rejected(pending.request, "connectionInvalidated"); pending.replies.forEach { $0(data) } }
    }
    private func submit(_ bytes: Data, cancel: Bool, reply: @escaping (Data) -> Void) {
        guard bytes.count <= 65536, let request = try? JSONDecoder().decode(REAScenarioCaptureRequest.self, from: bytes),
              request.isValid, (try? REACaptureCommitment.encode(request)) == bytes else { reply(Data()); return }
        var start: Operation?
        let immediate: Data? = lock.withLock {
            if let old = cached[request.requestID] { return old.0 == bytes ? old.1 : rejected(request, "requestIdentityMismatch") }
            guard !invalidated else { return rejected(request, "connectionInvalidated") }
            if let operation = active {
                guard operation.bytes == bytes else { return rejected(request, "busy") }
                operation.cancelled = operation.cancelled || cancel; operation.replies.append(reply)
                if !cancel && !operation.started { operation.started = true; start = operation }
                return nil
            }
            guard !seen.contains(request.requestID), seen.count < 65536 else { return rejected(request, "duplicateRequest") }
            let operation = Operation(request, bytes); operation.cancelled = cancel; operation.replies.append(reply)
            active = operation; seen.insert(request.requestID)
            if !cancel { operation.started = true; start = operation }
            return nil
        }
        if let immediate { reply(immediate) }
        if let start { queue.async { [self, start] in finish(start) } }
    }
    private func rejected(_ request: REAScenarioCaptureRequest, _ reason: String) -> Data {
        (try? REACaptureCommitment.encode(REAScenarioCaptureResponse.rejected(request, failure: reason))) ?? Data()
    }
    private func finish(_ operation: Operation) {
        let request = operation.request
        var response = REAScenarioCaptureResponse.rejected(request, failure: "admissionRejected")
        let admitted = Phase2ShellBrokerPrincipal.sourceAdmissionGate.begin()
        if admitted {
            defer { Phase2ShellBrokerPrincipal.sourceAdmissionGate.end() }
            do {
                if lock.withLock({ invalidated || operation.cancelled }) { throw REAScenarioCapture.Failure.invalidInput }
                let tree = try REAScenarioCapture.verify(request)
                let runner = try Self.runner(request)
                let plan = Phase2HumanPTYLaunchPlan(sessionID: request.sessionID, requestID: request.requestID,
                    executablePath: runner.path, arguments: ["scenario", request.stageRootPath], environment: [:],
                    workingDirectoryPath: request.stageRootPath, initialSize: .defaultInteractive,
                    transcriptLimits: .init(maximumEvents: 64, maximumEventBytes: 4096, maximumCumulativeBytes: 16384))
                let result = try adapter.executeSource(plan, cancelled: { [self, operation] in lock.withLock { invalidated || operation.cancelled } })
                var captureFailure = result.failure?.rawValue
                let treeAfter = try? REAScenarioCapture.verify(request)
                if treeAfter != tree || (try? Self.runner(request)) != runner { captureFailure = "identityChanged" }
                let root = URL(fileURLWithPath: request.stageRootPath).appendingPathComponent("output")
                var output: [Data] = []
                for name in ["stdout", "stderr"] {
                    do {
                        let file = root.appendingPathComponent(name).path
                        let fd = open(file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                        guard fd >= 0 else { throw REAScenarioCapture.Failure.invalidInput }
                        let status = fchmod(fd, 0o400); close(fd)
                        guard status == 0 else { throw REAScenarioCapture.Failure.invalidInput }
                        output.append(try REAScenarioCapture.fileBytes(file, maximum: 8192))
                    } catch { captureFailure = captureFailure ?? "channelSnapshotUnavailable"; output.append(Data()) }
                }
                let proof = result.cleanupProof
                let terminal = result.terminalOutcome.map(Self.terminal)
                let cleanup = CaptureCleanup(sessionID: proof.sessionID, requestID: proof.requestID,
                    processIdentifier: proof.processIdentifier, observedProcessAbsent: proof.observedProcessAbsent,
                    outcome: Self.terminal(proof.outcome))
                let failure = captureFailure ?? (output.contains(where: { $0.count >= 8192 }) ? "outputLimit" : nil)
                response = .init(requestID: request.requestID, sessionID: request.sessionID, receiptID: UUID(),
                    scenarioSHA256: request.scenarioSHA256, executableSHA256: request.executableSHA256,
                    materializedInputTreeSHA256: tree, status: .completed, failure: failure,
                    stdout: output[0], stderr: output[1], terminal: terminal, cleanup: cleanup,
                    elapsedSeconds: result.elapsedSeconds,
                    completeSources: failure == nil && proof.observedProcessAbsent ? ["stdout", "stderr", "exit"] : [])
            } catch { response = .rejected(request, failure: String(describing: error)) }
        }
        let data = (try? REACaptureCommitment.encode(response)) ?? Data()
        let replies = lock.withLock { () -> [(Data) -> Void] in
            guard active === operation else { return [] }
            active = nil; cached[request.requestID] = (operation.bytes, data)
            if cached.count > 64, let oldest = cached.keys.sorted(by: { $0.uuidString < $1.uuidString }).first { cached.removeValue(forKey: oldest) }
            return operation.replies
        }
        replies.forEach { $0(data) }
    }
    private static func terminal(_ value: Phase2HumanPTYTerminalOutcome) -> CaptureTerminal {
        switch value {
        case .exited(let status): return .init(kind: .exited, status: status)
        case .signaled(let signal):
            let status: Int32
            switch signal { case .interrupt: status = SIGINT; case .terminate: status = SIGTERM; case .suspend: status = SIGTSTP; case .continueSignal: status = SIGCONT }
            return .init(kind: .signaled, status: status)
        case .canceled: return .init(kind: .canceled, status: nil)
        case .interrupted: return .init(kind: .interrupted, status: nil)
        case .brokerCrashed: return .init(kind: .brokerCrashed, status: nil)
        case .outcomeUnknown: return .init(kind: .outcomeUnknown, status: nil)
        }
    }
    private static func runner(_ request: REAScenarioCaptureRequest) throws -> URL {
        guard var app = Bundle.main.executableURL else { throw REAScenarioCapture.Failure.invalidInput }
        var found = false
        for _ in 0..<8 { app.deleteLastPathComponent(); if app.pathExtension == "app" { found = true; break } }
        guard found else { throw REAScenarioCapture.Failure.invalidInput }
        let runner = app.appendingPathComponent("Contents/MacOS/SourceExecutionRunner")
        guard runner.resolvingSymlinksInPath().path == runner.path,
              REACaptureCommitment.digest(try REAScenarioCapture.fileBytes(runner.path, maximum: 268435456, executable: true, readOnly: false)) == request.runnerSHA256 else { throw REAScenarioCapture.Failure.invalidInput }
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(runner as CFURL, SecCSFlags(), &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(Phase2ShellBrokerPeerRequirement.sourceRunner as CFString, SecCSFlags(), &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess else { throw REAScenarioCapture.Failure.invalidInput }
        return runner
    }
}
