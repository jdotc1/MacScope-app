import Foundation
import Darwin

/// Each invocation owns a fresh authenticated connection. Invalidation ends a client
/// wait only; it is never evidence that the broker's process group has terminated.
protocol REAScenarioCaptureTransport: Sendable {
    func request(_ request: REAScenarioCaptureRequest) async throws -> Data
    func cancel(_ request: REAScenarioCaptureRequest)
    func retire()
}

final class REASignedScenarioCaptureTransport: REAScenarioCaptureTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var pending: REACaptureWaiter?
    private var used = false
    private var canceled = false

    func request(_ request: REAScenarioCaptureRequest) async throws -> Data {
        let bytes = try REACaptureCommitment.encode(request)
        let waiter = REACaptureWaiter()
        let channel = NSXPCConnection(machServiceName: Phase2ShellBrokerProtocolIdentity.persistentMachServiceName, options: [])
        channel.remoteObjectInterface = NSXPCInterface(with: Phase2ShellBrokerXPCProtocol.self)
        channel.setCodeSigningRequirement(Phase2ShellBrokerPeerRequirement.launchAgent)
        let admitted = lock.withLock { () -> Bool in
            guard !used, !canceled else { return false }
            used = true; connection = channel; pending = waiter; return true
        }
        guard admitted else { throw REAScenarioCaptureProvider.Failure.unavailable }
        channel.interruptionHandler = { [weak self] in self?.retire() }
        channel.invalidationHandler = { [weak self] in self?.retire() }
        channel.resume()
        guard let proxy = channel.remoteObjectProxyWithErrorHandler({ error in
            waiter.finish(.failure(error))
        }) as? Phase2ShellBrokerXPCProtocol else {
            retire(); throw REAScenarioCaptureProvider.Failure.unavailable
        }
        proxy.handshake { data in
            do {
                guard data.count <= Phase2ShellBrokerProtocolIdentity.maximumMessageBytes else {
                    throw REAScenarioCaptureProvider.Failure.invalidReply
                }
                let hello = try Phase2ShellBrokerWireCodec.decodeHandshake(data)
                guard hello.schemaVersion == Phase2ShellBrokerProtocolIdentity.schemaVersion,
                      hello.serviceIdentifier == Phase2ShellBrokerProtocolIdentity.serviceIdentifier,
                      hello.wireProtocol == Phase2ShellBrokerProtocolIdentity.wireProtocol,
                      hello.status == .boundaryReady,
                      hello.maximumMessageBytes == Phase2ShellBrokerProtocolIdentity.maximumMessageBytes else {
                    throw REAScenarioCaptureProvider.Failure.invalidReply
                }
                guard !waiter.isFinished else { return }
                proxy.executeScenario(bytes) { waiter.finish(.success($0)) }
            } catch { waiter.finish(.failure(error)) }
        }
        return try await waiter.value()
    }
    func cancel(_ request: REAScenarioCaptureRequest) {
        let channel = lock.withLock { canceled = true; return connection }
        guard let channel, let data = try? REACaptureCommitment.encode(request),
              let proxy = channel.remoteObjectProxyWithErrorHandler({ _ in }) as? Phase2ShellBrokerXPCProtocol else { return }
        proxy.cancelScenario(data) { _ in }
    }
    func retire() {
        let saved = lock.withLock { () -> (NSXPCConnection?, REACaptureWaiter?) in
            used = true; canceled = true
            let saved = (connection, pending); connection = nil; pending = nil; return saved
        }
        saved.1?.finish(.failure(REAScenarioCaptureProvider.Failure.unavailable))
        saved.0?.invalidationHandler = nil; saved.0?.interruptionHandler = nil
        saved.0?.invalidate()
    }
}

final class REAScenarioCaptureProvider: Sendable {
    enum Failure: Error, Equatable, Sendable { case invalidInput, invalidReply, rejected, timeout, unavailable }
    /// Construction is restricted to verified producer admission; snapshots retain
    /// their channel identity and make no claim about interchannel execution order.
    struct AcceptedCapture: Sendable {
        let request: REAScenarioCaptureRequest
        let response: REAScenarioCaptureResponse
        let producerReceiptSHA256: String
        fileprivate init(request: REAScenarioCaptureRequest, response: REAScenarioCaptureResponse) throws {
            self.request = request; self.response = response
            producerReceiptSHA256 = try REACaptureCommitment.digest(REACaptureCommitment.encode(response))
        }
    }
    private let makeTransport: @Sendable () -> any REAScenarioCaptureTransport
    private let timeoutNanoseconds: UInt64
    init(timeout: TimeInterval = 30,
         makeTransport: @escaping @Sendable () -> any REAScenarioCaptureTransport = { REASignedScenarioCaptureTransport() }) {
        self.makeTransport = makeTransport
        timeoutNanoseconds = UInt64(min(max(timeout.isFinite ? timeout : 30, 0.001), 30) * 1_000_000_000)
    }
    func capture(_ request: REAScenarioCaptureRequest) async throws -> AcceptedCapture {
        try Task.checkCancellation()
        guard request.isValid else { throw Failure.invalidInput }
        _ = try REAScenarioCapture.verify(request)
        let transport = makeTransport(), waiter = REACaptureWaiter()
        let timer = Task {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            waiter.finish(.failure(Failure.timeout)) { transport.cancel(request); transport.retire() }
        }
        Task {
            do { waiter.finish(.success(try await transport.request(request))) }
            catch { waiter.finish(.failure(error)) }
        }
        let bytes: Data
        do {
            bytes = try await withTaskCancellationHandler {
                try await waiter.value()
            } onCancel: {
                waiter.finish(.failure(CancellationError())) { transport.cancel(request); transport.retire() }
            }
        } catch { timer.cancel(); transport.retire(); throw error }
        timer.cancel(); defer { transport.retire() }
        guard bytes.count <= 65536,
              let response = try? JSONDecoder().decode(REAScenarioCaptureResponse.self, from: bytes),
              (try? REACaptureCommitment.encode(response)) == bytes,
              response.requestID == request.requestID, response.sessionID == request.sessionID,
              response.scenarioSHA256 == request.scenarioSHA256,
              response.executableSHA256 == request.executableSHA256 else { throw Failure.invalidReply }
        // Only an authenticated, request-bound cleanup receipt permits stage removal.
        if response.cleanup?.requestID == request.requestID,
           response.cleanup?.sessionID == request.sessionID,
           response.cleanup?.observedProcessAbsent == true,
           response.cleanup?.outcome == response.terminal,
           (response.cleanup?.processIdentifier ?? 0) > 1 {
            try Self.removeStage(request.stageRootPath)
        }
        guard response.isAccepted,
              response.materializedInputTreeSHA256 == request.scenario.inputTreeSHA256 else { throw Failure.rejected }
        try Task.checkCancellation()
        return try AcceptedCapture(request: request, response: response)
    }

    /// All hashes are derived from bytes staged by this caller. The committed
    /// scenario must already describe the resulting input tree; it is never rewritten.
    static func stage(executable: URL, runner: URL, scenario: REAProcessScenario,
                      files: [String: Data], directories: [String] = [],
                      parent: URL = MacScopeWorkRoot.url.appendingPathComponent("REA-Captures", isDirectory: true)) throws -> REAScenarioCaptureRequest {
        guard scenario.isSupported, files.count + directories.count <= 1024,
              files.values.allSatisfy({ $0.count <= 1_048_576 }),
              files.values.reduce(0, { $0 + $1.count }) <= 16_777_216,
              (Array(files.keys) + directories).allSatisfy({ $0 != "." && REAProcessScenario.safeRelative($0) && $0.split(separator: "/").count <= 16 }),
              MacScopeWorkRoot.contains(parent.path),
              parent.standardizedFileURL.path == parent.path,
              parent.resolvingSymlinksInPath().path == parent.path else { throw Failure.invalidInput }
        let executableBytes = try REAScenarioCapture.fileBytes(executable.path, maximum: 16_777_216, executable: true, readOnly: false)
        let runnerBytes = try REAScenarioCapture.fileBytes(runner.path, maximum: 16_777_216, executable: true, readOnly: false)
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(parent.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o077 == 0 else { throw Failure.invalidInput }
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            func write(_ data: Data, _ url: URL, _ mode: Int) throws {
                guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: mode]) else { throw Failure.invalidInput }
            }
            try write(executableBytes, root.appendingPathComponent("executable"), 0o500)
            try write(REAScenarioCapture.nulBytes(scenario.arguments), root.appendingPathComponent("arguments.bin"), 0o400)
            try write(REAScenarioCapture.environmentBytes(scenario.environment), root.appendingPathComponent("environment.bin"), 0o400)
            try write(Data(scenario.workingDirectory.utf8), root.appendingPathComponent("working-directory.bin"), 0o400)
            let input = root.appendingPathComponent("input", isDirectory: true)
            try fm.createDirectory(at: input, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for path in directories.sorted() {
                try fm.createDirectory(at: input.appendingPathComponent(path), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            for path in files.keys.sorted() {
                let url = input.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try write(files[path]!, url, 0o400)
            }
            let children = try fm.subpathsOfDirectory(atPath: input.path)
            for path in children.sorted(by: { $0.count > $1.count }) {
                let url = input.appendingPathComponent(path)
                guard lstat(url.path, &info) == 0 else { throw Failure.invalidInput }
                if info.st_mode & S_IFMT == S_IFDIR { guard chmod(url.path, 0o500) == 0 else { throw Failure.invalidInput } }
            }
            guard chmod(input.path, 0o500) == 0 else { throw Failure.invalidInput }
            let request = REAScenarioCaptureRequest(requestID: UUID(), sessionID: UUID(), stageRootPath: root.path,
                scenario: scenario, scenarioSHA256: try REACaptureCommitment.sha256(scenario),
                executableSHA256: REACaptureCommitment.digest(executableBytes), executableByteCount: UInt64(executableBytes.count),
                runnerSHA256: REACaptureCommitment.digest(runnerBytes))
            _ = try REAScenarioCapture.verify(request)
            return request
        } catch { try? removeStage(root.path); throw error }
    }
    private static func removeStage(_ path: String) throws {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard MacScopeWorkRoot.contains(path), root.resolvingSymlinksInPath().path == path else { throw Failure.invalidInput }
        let fm = FileManager.default
        for child in (try fm.subpathsOfDirectory(atPath: path)).sorted(by: { $0.count < $1.count }) {
            let url = root.appendingPathComponent(child); var info = stat()
            guard lstat(url.path, &info) == 0 else { throw Failure.invalidInput }
            if info.st_mode & S_IFMT == S_IFDIR { guard chmod(url.path, 0o700) == 0 else { throw Failure.invalidInput } }
        }
        try fm.removeItem(at: root)
    }
}

private final class REACaptureWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error>?
    private var continuation: CheckedContinuation<Data, Error>?
    var isFinished: Bool { lock.withLock { result != nil } }
    @discardableResult func finish(_ value: Result<Data, Error>, beforeResume: () -> Void = {}) -> Bool {
        let saved = lock.withLock { () -> (Bool, CheckedContinuation<Data, Error>?) in
            guard result == nil else { return (false, nil) }
            result = value; let saved = continuation; continuation = nil; return (true, saved)
        }
        if saved.0 { beforeResume() }
        saved.1?.resume(with: value); return saved.0
    }
    func value() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let saved = lock.withLock { () -> Result<Data, Error>? in
                if let result { return result }; self.continuation = continuation; return nil
            }
            if let saved { continuation.resume(with: saved) }
        }
    }
}
