import Foundation
import Darwin
import Security
import CryptoKit
#if TESTING_SHELL_BROKER_PRINCIPAL
@testable import MacScope
#endif

final class Phase2ShellBrokerPrincipal: NSObject, Phase2ShellBrokerXPCProtocol, @unchecked Sendable {
    private struct CachedCommandResponse {
        let requestData: Data
        let responseData: Data
    }

    private struct SessionRecord {
        var snapshot: Phase2ShellBrokerLifecycleSnapshot
        var lease: Phase2ShellBrokerProcessLease?
        var transcriptEvents: [Phase2HumanPTYTranscriptEvent] = []
        var nextTranscriptSequence: UInt64 = 1
        var transcriptLimits: Phase2HumanPTYTranscriptLimits = .productionMaximum
    }

    final class SourceAdmissionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var busy = false
        func begin() -> Bool {
            lock.withLock { guard !busy else { return false }; busy = true; return true }
        }
        func end() { lock.withLock { busy = false } }
    }
    static let sourceAdmissionGate = SourceAdmissionGate()
    private final class SourceOperation: @unchecked Sendable {
        let request: Phase2SourceExecutionRequest
        let bytes: Data
        var cancelled = false
        var replies: [(Data) -> Void] = []
        init(request: Phase2SourceExecutionRequest, bytes: Data) { self.request = request; self.bytes = bytes }
    }
    private let assetCatalogCapture = REAAssetCatalogCaptureService()
    private let scenarioCapture = REAScenarioCaptureService()
    private let sourceQueue = DispatchQueue(label: "org.macscope.app.source-execution", qos: .userInitiated)
    private var sourceOperation: SourceOperation?
    private var sourceResponses: [UUID: CachedCommandResponse] = [:]
    private var sourceResponseOrder: [UUID] = []
    private var sourceSeenIDs: Set<UUID> = []
    private let sourcePlanAuthority: @Sendable (Phase2SourceExecutionRequest) throws -> Phase2HumanPTYLaunchPlan
    private let sourceExecutor: @Sendable (Phase2HumanPTYLaunchPlan, @Sendable () -> Bool) throws -> ReconstructionSourceExecutionResult
    private let lock = NSLock()
    private let commandLock = NSLock()
    private let durableTransferLock = NSLock()
#if TESTING_SHELL_BROKER_PRINCIPAL
    var writeInputForTesting: ((Phase2ShellBrokerProcessLease, [UInt8]) throws -> Int)?
#endif
    private let processAdapter: Phase2ShellBrokerProcessAdapter
    private let durableRegistry: Phase2DurableShellBrokerRegistry
    private let clientID: UUID
    private var invalidated = false
    private var sessions: [UUID: SessionRecord] = [:]
    private var durableSessionIDs: Set<UUID> = []
    private var cachedCommandResponses: [UUID: CachedCommandResponse] = [:]
    private var cachedCommandOrder: [UUID] = []
    private var seenCommandIDs: Set<UUID> = []
    private static let maximumCachedCommandResponses = 64
    private let maximumSeenCommandIDs: Int

    init(
        processAdapter: Phase2ShellBrokerProcessAdapter = Phase2ShellBrokerProcessAdapter(),
        durableRegistry: Phase2DurableShellBrokerRegistry = Phase2DurableShellBrokerRegistry(),
        clientID: UUID = UUID(),
        maximumSeenCommandIDs: Int = 65_536,
        sourcePlanAuthority: @escaping @Sendable (Phase2SourceExecutionRequest) throws -> Phase2HumanPTYLaunchPlan = {
            try Phase2ShellBrokerPrincipal.makeSourceLaunchPlan($0)
        },
        sourceExecutor: (@Sendable (Phase2HumanPTYLaunchPlan, @Sendable () -> Bool) throws -> ReconstructionSourceExecutionResult)? = nil
    ) {
        self.processAdapter = processAdapter
        self.durableRegistry = durableRegistry
        self.clientID = clientID
        self.maximumSeenCommandIDs = min(max(maximumSeenCommandIDs, 1), 65_536)
        self.sourcePlanAuthority = sourcePlanAuthority
        self.sourceExecutor = sourceExecutor ?? { plan, cancelled in
            try processAdapter.executeSource(plan, cancelled: cancelled)
        }
    }

    func handshake(with reply: @escaping (Data) -> Void) {
        let responseData = commandLock.withLock { () -> Data in
            let isInvalidated = lock.withLock { invalidated }
            guard !isInvalidated else { return Data() }
            let handshake = Phase2ShellBrokerHandshake.boundaryReady(
                brokerIncarnationID: durableRegistry.brokerIncarnationID
            )
            return (try? Phase2ShellBrokerWireCodec.encodeHandshake(handshake)) ?? Data()
        }
        reply(responseData)
    }

    func performCommand(_ requestData: Data, with reply: @escaping (Data) -> Void) {
        let responseData = commandLock.withLock {
            performCommandLocked(requestData)
        }
        reply(responseData)
    }

    private func performCommandLocked(_ requestData: Data) -> Data {
        let isInvalidated = lock.withLock { invalidated }
        guard !isInvalidated else {
            return Data()
        }
        guard requestData.count <= Phase2ShellBrokerProtocolIdentity.maximumMessageBytes else {
            let response = Phase2ShellBrokerCommandResponse(
                commandID: nil,
                command: nil,
                status: .invalid,
                issues: ["messageTooLarge(bytes: \(requestData.count), maximum: \(Phase2ShellBrokerProtocolIdentity.maximumMessageBytes))"]
            )
            return encodeBoundedCommandResponse(response)
        }

        let request: Phase2ShellBrokerCommandRequest
        do {
            request = try Phase2ShellBrokerWireCodec.decodeCommandRequest(requestData)
        } catch {
            let response = Phase2ShellBrokerCommandResponse(
                commandID: nil,
                command: nil,
                status: .invalid,
                issues: ["invalidCommandEnvelope: \(error)"]
            )
            return encodeBoundedCommandResponse(response)
        }
        if let cached = cachedCommandResponses[request.commandID] {
            guard cached.requestData == requestData else {
                let response = Phase2ShellBrokerCommandResponse(
                    commandID: request.commandID,
                    command: request.command,
                    status: .rejected,
                    issues: ["duplicateCommandIdentifier"]
                )
                return encodeBoundedCommandResponse(response)
            }
            return cached.responseData
        }
        guard !seenCommandIDs.contains(request.commandID) else {
            let response = Phase2ShellBrokerCommandResponse(
                commandID: request.commandID,
                command: request.command,
                status: .rejected,
                issues: ["duplicateCommandIdentifier"]
            )
            return encodeBoundedCommandResponse(response)
        }
        guard request.command == .pollTranscript || seenCommandIDs.count < maximumSeenCommandIDs else {
            let response = Phase2ShellBrokerCommandResponse(
                commandID: request.commandID,
                command: request.command,
                status: .rejected,
                issues: ["commandIdentifierCapacityExceeded"]
            )
            return encodeBoundedCommandResponse(response)
        }

        let response: Phase2ShellBrokerCommandResponse
        do {
            switch request.command {
            case .launchProcess:
                let launchRequest = try Phase2ShellBrokerWireCodec.decodeLaunchProcessRequest(request.payload)
                response = handleLaunch(commandID: request.commandID, request: launchRequest)
            case .cleanupProcess:
                let cleanupRequest = try Phase2ShellBrokerWireCodec.decodeCleanupProcessRequest(request.payload)
                response = handleCleanup(commandID: request.commandID, request: cleanupRequest)
            case .writeInput:
                let inputRequest = try Phase2ShellBrokerWireCodec.decodeWriteInputRequest(request.payload)
                response = handleWriteInput(commandID: request.commandID, request: inputRequest)
            case .resizeTerminal:
                let resizeRequest = try Phase2ShellBrokerWireCodec.decodeResizeTerminalRequest(request.payload)
                response = handleResize(commandID: request.commandID, request: resizeRequest)
            case .sendSignal:
                let signalRequest = try Phase2ShellBrokerWireCodec.decodeSendSignalRequest(request.payload)
                response = handleSignal(commandID: request.commandID, request: signalRequest)
            case .pollTranscript:
                let pollRequest = try Phase2ShellBrokerWireCodec.decodePollTranscriptRequest(request.payload)
                response = handlePollTranscript(commandID: request.commandID, request: pollRequest)
            case .reconnectSession:
                let reconnectRequest = try Phase2ShellBrokerWireCodec.decodeReconnectSessionRequest(request.payload)
                response = handleReconnect(commandID: request.commandID, request: reconnectRequest)
            case .launchDurableProcess:
                let durableRequest = try Phase2ShellBrokerWireCodec.decodeLaunchDurableProcessRequest(request.payload)
                response = handleLaunchDurable(commandID: request.commandID, request: durableRequest)
            case .commitDurableSession, .durableSessionStatus, .attachDurableSession, .detachDurableSession,
                    .heartbeatDurableSession:
                let durableRequest = try Phase2ShellBrokerWireCodec.decodeDurableSessionRequest(request.payload)
                response = handleDurableSessionCommand(
                    commandID: request.commandID,
                    command: request.command,
                    request: durableRequest
                )
            }
        } catch {
            response = Phase2ShellBrokerCommandResponse(
                commandID: request.commandID,
                command: request.command,
                status: .invalid,
                issues: ["invalidCommandEnvelope: \(error)"]
            )
        }

        let responseData = encodeBoundedCommandResponse(response)
        if !responseData.isEmpty {
            cacheCompletedCommand(requestData: requestData, responseData: responseData,
                                  commandID: request.commandID, command: request.command)
        }
        return responseData
    }

    func invalidate() {
        scenarioCapture.invalidate()
        assetCatalogCapture.invalidate()
        let unstartedReplies = lock.withLock { () -> [(Data) -> Void] in
            sourceOperation?.cancelled = true
            guard let pending = sourceOperation, !sourceSeenIDs.contains(pending.request.requestID) else { return [] }
            sourceOperation = nil
            let data = sourceResponseData(.rejected(pending.request, failure: .cancelled))
            return pending.replies.map { callback in { _ in callback(data) } }
        }
        unstartedReplies.forEach { $0(Data()) }
        commandLock.lock()
        defer { commandLock.unlock() }
        durableTransferLock.lock()
        defer { durableTransferLock.unlock() }
        let (ordinaryLeases, durableIDs) = lock.withLock {
            invalidated = true
            let leases = sessions.compactMap { sessionID, record in
                durableSessionIDs.contains(sessionID) ? nil : record.lease
            }
            let durableIDs = durableSessionIDs
            sessions.removeAll()
            durableSessionIDs.removeAll()
            cachedCommandResponses.removeAll()
            cachedCommandOrder.removeAll()
            seenCommandIDs.removeAll()
            return (leases, durableIDs)
        }

        if !durableIDs.isEmpty {
            durableRegistry.detachClient(clientID)
        }
        for lease in ordinaryLeases {
            _ = lease.cleanup(outcome: .canceled, timeout: 1.0)
        }
    }


    func executeAssetCatalog(_ requestData: Data, with reply: @escaping (Data) -> Void) { assetCatalogCapture.execute(requestData, reply: reply) }
    func cancelAssetCatalog(_ requestData: Data, with reply: @escaping (Data) -> Void) { assetCatalogCapture.cancel(requestData, reply: reply) }

    func executeScenario(_ requestData: Data, with reply: @escaping (Data) -> Void) { scenarioCapture.execute(requestData, reply: reply) }
    func cancelScenario(_ requestData: Data, with reply: @escaping (Data) -> Void) { scenarioCapture.cancel(requestData, reply: reply) }

    /// Source work cannot hold commandLock: cancellation and disconnect must reach the lease.
    func executeSource(_ requestData: Data, with reply: @escaping (Data) -> Void) {
        guard let request = try? Phase2SourceExecutionWireCodec.decodeRequest(requestData) else {
            reply(sourceResponseData(.rejected(nil))); return
        }
        var start: SourceOperation?
        let immediate: Data? = lock.withLock {
            if invalidated { return sourceResponseData(.rejected(request)) }
            if let cached = sourceResponses[request.requestID] {
                return cached.requestData == requestData ? cached.responseData : sourceResponseData(.rejected(request))
            }
            if let active = sourceOperation {
                guard active.request.requestID == request.requestID, active.bytes == requestData else {
                    return sourceResponseData(.rejected(request))
                }
                active.replies.append(reply)
                // A cancellation arriving before execution reserved this operation but did not start it.
                if !sourceSeenIDs.contains(request.requestID) {
                    sourceSeenIDs.insert(request.requestID); start = active
                }
                return nil
            }
            guard !sourceSeenIDs.contains(request.requestID), sourceSeenIDs.count < 65_536 else {
                return sourceResponseData(.rejected(request))
            }
            let operation = SourceOperation(request: request, bytes: requestData)
            operation.replies.append(reply); sourceOperation = operation
            sourceSeenIDs.insert(request.requestID); start = operation
            return nil
        }
        if let immediate { reply(immediate) }
        if let start {
            sourceQueue.async { [self, start] in finishSource(start) }
        }
    }

    /// Cancellation replies only after execution has produced its terminal cleanup result.
    /// The full canonical request binds a cancellation to the exact admitted operation.
    func cancelSource(_ requestData: Data, with reply: @escaping (Data) -> Void) {
        guard let request = try? Phase2SourceExecutionWireCodec.decodeRequest(requestData) else {
            reply(sourceResponseData(.rejected(nil))); return
        }
        let immediate: Data? = lock.withLock {
            if let cached = sourceResponses[request.requestID] {
                return cached.requestData == requestData ? cached.responseData : sourceResponseData(.rejected(request))
            }
            if let active = sourceOperation {
                guard active.request.requestID == request.requestID, active.bytes == requestData else {
                    return sourceResponseData(.rejected(request))
                }
                active.cancelled = true; active.replies.append(reply); return nil
            }
            guard !invalidated, !sourceSeenIDs.contains(request.requestID), sourceSeenIDs.count < 65_536 else {
                return sourceResponseData(.rejected(request))
            }
            // Transport cancellation can precede XPC execute delivery. Keep one bounded tombstone.
            let pending = SourceOperation(request: request, bytes: requestData)
            pending.cancelled = true; pending.replies.append(reply); sourceOperation = pending
            return nil
        }
        if let immediate { reply(immediate) }
    }

    private func finishSource(_ operation: SourceOperation) {
        let response: Phase2SourceExecutionResponse
        let admitted = Self.sourceAdmissionGate.begin()
        if !admitted {
            response = .rejected(operation.request)
        } else {
            do {
                let plan = try sourcePlanAuthority(operation.request)
                let result = try sourceExecutor(plan, { [self, operation] in
                    lock.withLock { invalidated || operation.cancelled }
                })
                // A changed helper, toolchain or source invalidates every result, including exit zero.
                let inputsStillValid = (try? sourcePlanAuthority(operation.request)) == plan
                let cleanup = result.cleanupProof
                response = .init(requestID: operation.request.requestID, sessionID: operation.request.sessionID,
                    operation: operation.request.operation, status: .completed,
                    failure: !inputsStillValid ? .authorityRejected : result.failure.flatMap {
                        Phase2SourceExecutionFailure(rawValue: $0.rawValue)
                    }, terminal: result.terminalOutcome.map(Self.sourceTerminal), diagnostics: result.diagnostics,
                    peakGroupResidentBytes: result.peakGroupResidentBytes, sampledProcessIDs: result.sampledProcessIDs,
                    elapsedSeconds: result.elapsedSeconds,
                    cleanup: .init(sessionID: cleanup.sessionID, requestID: cleanup.requestID,
                        processIdentifier: cleanup.processIdentifier, observedProcessAbsent: cleanup.observedProcessAbsent,
                        outcome: Self.sourceTerminal(cleanup.outcome)))
            } catch {
                response = .rejected(operation.request, failure: .launchFailed)
            }
        }
        // All helper execution and cleanup is complete before another connection is admitted.
        if admitted { Self.sourceAdmissionGate.end() }
        let bytes = sourceResponseData(response)
        let replies = lock.withLock { () -> [(Data) -> Void] in
            guard sourceOperation === operation else { return [] }
            sourceResponses[operation.request.requestID] = .init(requestData: operation.bytes, responseData: bytes)
            sourceResponseOrder.append(operation.request.requestID)
            while sourceResponseOrder.count > 64 {
                sourceResponses.removeValue(forKey: sourceResponseOrder.removeFirst())
            }
            sourceOperation = nil
            return operation.replies
        }
        replies.forEach { $0(bytes) }
    }

    private func sourceResponseData(_ value: Phase2SourceExecutionResponse) -> Data {
        (try? Phase2SourceExecutionWireCodec.encodeResponse(value)) ?? Data()
    }
    private static func sourceTerminal(_ outcome: Phase2HumanPTYTerminalOutcome) -> Phase2SourceExecutionTerminal {
        switch outcome {
        case .exited(let status): return .init(kind: .exited, status: status)
        case .signaled(let signal):
            let status: Int32 = switch signal {
            case .interrupt: SIGINT
            case .terminate: SIGTERM
            case .suspend: SIGTSTP
            case .continueSignal: SIGCONT
            }
            return .init(kind: .signaled, status: status)
        case .canceled: return .init(kind: .canceled, status: nil)
        case .interrupted: return .init(kind: .interrupted, status: nil)
        case .brokerCrashed: return .init(kind: .brokerCrashed, status: nil)
        case .outcomeUnknown: return .init(kind: .outcomeUnknown, status: nil)
        }
    }

    /// No request selects a runner or arbitrary argv. Resolve the exact helper from this signed app.
    private static func makeSourceLaunchPlan(_ request: Phase2SourceExecutionRequest) throws -> Phase2HumanPTYLaunchPlan {
        enum Rejection: Error { case invalidAuthority }
        func reject() throws -> Never { throw Rejection.invalidAuthority }
        func canonical(_ path: String) -> Bool {
            let url = URL(fileURLWithPath: path)
            return url.standardizedFileURL.path == path && url.resolvingSymlinksInPath().path == path
        }
        // Accepted only from a read window in which identity, size, mtime and ctime held still; a
        // metadata-only change during the read (seen on the shared Xcode clang under parallel test
        // hosts) re-reads, and three unstable windows in a row reject.
        func digest(_ path: String, maximum: Int64) throws -> String {
            for _ in 0..<3 {
                if let value = try digestOnce(path, maximum: maximum) { return value }
            }
            try reject()
        }
        func digestOnce(_ path: String, maximum: Int64) throws -> String? {
            let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { try reject() }; defer { close(descriptor) }
            var before = stat(), after = stat(), current = stat()
            guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
                  before.st_nlink == 1, (before.st_mode & 0o022) == 0,
                  before.st_size > 0, before.st_size <= maximum else { try reject() }
            var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 65536), total: Int64 = 0
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { try reject() }; if count == 0 { break }
                total += Int64(count); guard total <= maximum else { try reject() }
                hash.update(data: Data(buffer.prefix(count)))
            }
            guard fstat(descriptor, &after) == 0, lstat(path, &current) == 0,
                  before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  after.st_dev == current.st_dev, after.st_ino == current.st_ino,
                  before.st_size == total, after.st_size == total else { try reject() }
            guard before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { return nil }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        func signed(_ path: URL, requirementText: String) throws {
            var code: SecStaticCode?, requirement: SecRequirement?
            guard SecStaticCodeCreateWithPath(path as CFURL, SecCSFlags(), &code) == errSecSuccess,
                  let code, SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement) == errSecSuccess,
                  let requirement, SecStaticCodeCheckValidity(code,
                    SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess else { try reject() }
        }
        guard request.isValid, request.sourceProfile == .scalarU32V1, canonical(request.stageRootPath) else { try reject() }
        var rootStat = stat()
        guard lstat(request.stageRootPath, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR,
              rootStat.st_uid == getuid(), (rootStat.st_mode & 0o777) == 0o700 else { try reject() }
        let stage = URL(fileURLWithPath: request.stageRootPath, isDirectory: true)
        for filename in ["candidate.c", "harness.c"] {
            var fileStat = stat()
            guard lstat(stage.appendingPathComponent(filename).path, &fileStat) == 0,
                  (fileStat.st_mode & S_IFMT) == S_IFREG, fileStat.st_uid == getuid(),
                  fileStat.st_nlink == 1, (fileStat.st_mode & 0o777) == 0o400 else { try reject() }
        }
        guard try digest(stage.appendingPathComponent("candidate.c").path, maximum: 65536) == request.sourceSHA256,
              try digest(stage.appendingPathComponent("harness.c").path, maximum: 65536) == request.harnessSHA256 else { try reject() }
        let selected = try FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")
        let developer = URL(fileURLWithPath: selected).resolvingSymlinksInPath().standardizedFileURL
        guard developer.path.hasPrefix("/Applications/"), developer.path.hasSuffix(".app/Contents/Developer") else { try reject() }
        let toolchain = developer.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain").resolvingSymlinksInPath()
        let compiler = toolchain.appendingPathComponent("usr/bin/clang").resolvingSymlinksInPath()
        let sdk = developer.appendingPathComponent("Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk").resolvingSymlinksInPath()
        guard request.compilerPath == compiler.path, request.toolchainRootPath == toolchain.path,
              request.sdkRootPath == sdk.path,
              try digest(compiler.path, maximum: 268435456) == request.compilerSHA256,
              try digest(sdk.appendingPathComponent("SDKSettings.json").path, maximum: 1048576) == request.sdkSettingsSHA256 else { try reject() }
        try signed(compiler, requirementText: "anchor apple")
        guard var app = Bundle.main.executableURL else { try reject() }
        var found = false
        for _ in 0..<8 {
            app.deleteLastPathComponent()
            if app.pathExtension == "app" { found = true; break }
        }
        guard found, canonical(app.path) else { try reject() }
        try signed(app, requirementText: Phase2ShellBrokerPeerRequirement.app)
        let runner = app.appendingPathComponent("Contents/MacOS/SourceExecutionRunner")
        guard canonical(runner.path), access(runner.path, X_OK) == 0,
              try digest(runner.path, maximum: 268435456) == request.runnerSHA256 else { try reject() }
        try signed(runner, requirementText: Phase2ShellBrokerPeerRequirement.sourceRunner)
        let arguments = request.operation == .behavior ? ["behavior", stage.path]
            : [request.operation.rawValue, stage.path, compiler.path, sdk.path, toolchain.path]
        return .init(sessionID: request.sessionID, requestID: request.requestID,
            executablePath: runner.path, arguments: arguments, environment: [:], workingDirectoryPath: stage.path,
            initialSize: .defaultInteractive,
            transcriptLimits: .init(maximumEvents: 64, maximumEventBytes: 4096, maximumCumulativeBytes: 16384))
    }

    private func cacheCompletedCommand(requestData: Data, responseData: Data,
                                       commandID: UUID, command: Phase2ShellBrokerCommandKind) {
        // Observation invocations can be re-executed after bounded-cache eviction. Mutations
        // retain lifetime protection even when their cached response has been evicted.
        if command != .pollTranscript { seenCommandIDs.insert(commandID) }
        cachedCommandResponses[commandID] = CachedCommandResponse(
            requestData: requestData,
            responseData: responseData
        )
        cachedCommandOrder.append(commandID)
        while cachedCommandOrder.count > Self.maximumCachedCommandResponses {
            let evicted = cachedCommandOrder.removeFirst()
            cachedCommandResponses.removeValue(forKey: evicted)
        }
    }

    private func encodeBoundedCommandResponse(_ response: Phase2ShellBrokerCommandResponse) -> Data {
        guard let encoded = try? Phase2ShellBrokerWireCodec.encodeCommandResponse(response) else {
            return Data()
        }
        guard encoded.count <= Phase2ShellBrokerProtocolIdentity.maximumMessageBytes else {
            let boundedFailure = Phase2ShellBrokerCommandResponse(
                commandID: response.commandID,
                command: response.command,
                status: .failed,
                sessionID: response.sessionID,
                requestID: response.requestID,
                issues: ["responseTooLarge"]
            )
            return (try? Phase2ShellBrokerWireCodec.encodeCommandResponse(boundedFailure)) ?? Data()
        }
        return encoded
    }

    private func handleLaunchDurable(
        commandID: UUID,
        request: Phase2ShellBrokerLaunchDurableProcessRequest
    ) -> Phase2ShellBrokerCommandResponse {
        durableTransferLock.lock()
        defer { durableTransferLock.unlock() }
        guard request.launch.sessionID == request.durableLaunch.sessionID,
              request.launch.requestID == request.durableLaunch.requestID,
              request.launch.executablePath == request.durableLaunch.executablePath,
              request.launch.arguments == request.durableLaunch.arguments,
              request.launch.workingDirectoryPath == request.durableLaunch.workingDirectoryPath,
              request.durableLaunch.brokerIncarnationID == durableRegistry.brokerIncarnationID
        else {
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .launchDurableProcess,
                status: .rejected,
                sessionID: request.launch.sessionID,
                requestID: request.launch.requestID,
                issues: ["durableLaunchIdentityMismatch"]
            )
        }

        let ordinaryResponse = handleLaunch(commandID: commandID, request: request.launch)
        guard ordinaryResponse.status == .accepted,
              let sessionRecord = lock.withLock({ sessions[request.launch.sessionID] }),
              let lease = sessionRecord.lease
        else {
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .launchDurableProcess,
                status: ordinaryResponse.status,
                sessionID: ordinaryResponse.sessionID,
                requestID: ordinaryResponse.requestID,
                lifecycleState: ordinaryResponse.lifecycleState,
                processIdentifier: ordinaryResponse.processIdentifier,
                executablePath: ordinaryResponse.executablePath,
                issues: ordinaryResponse.issues
            )
        }

        do {
            // Ownership transfers before registry publication so no concurrent command can
            // fall back to the ordinary-session PTY reader during the registration window.
            _ = lock.withLock { durableSessionIDs.insert(request.launch.sessionID) }
            let identity = try durableRegistry.register(
                launchRequest: request.durableLaunch,
                capabilitySecretBytes: request.capabilitySecretBytes,
                lease: lease,
                clientID: clientID,
                initialTranscriptEvents: sessionRecord.transcriptEvents,
                nextTranscriptSequence: sessionRecord.nextTranscriptSequence
            )
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .launchDurableProcess,
                status: .accepted,
                sessionID: identity.sessionID,
                requestID: identity.launchRequest.requestID,
                lifecycleState: ordinaryResponse.lifecycleState,
                processIdentifier: identity.processIdentity.processIdentifier,
                executablePath: identity.processIdentity.executablePath,
                durableIdentity: identity,
                durableClientAttached: true
            )
        } catch {
            let proof = lease.cleanup(outcome: .canceled, timeout: 1.0)
            lock.withLock {
                sessions.removeValue(forKey: request.launch.sessionID)
                durableSessionIDs.remove(request.launch.sessionID)
            }
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .launchDurableProcess,
                status: .failed,
                sessionID: request.launch.sessionID,
                requestID: request.launch.requestID,
                processIdentifier: proof.processIdentifier,
                observedProcessAbsent: proof.observedProcessAbsent,
                issues: ["durableRegistrationFailed: \(error)"]
            )
        }
    }

    private func handleDurableSessionCommand(
        commandID: UUID,
        command: Phase2ShellBrokerCommandKind,
        request: Phase2ShellBrokerDurableSessionRequest
    ) -> Phase2ShellBrokerCommandResponse {
        let authentication: Phase2DurableShellBrokerAuthenticationRequest
        do {
            authentication = try request.authentication.makeAuthenticationRequest()
        } catch {
            return durableAuthenticationFailure(commandID: commandID, command: command)
        }

        do {
            switch command {
            case .commitDurableSession:
                let identity = try durableRegistry.commit(
                    authentication: authentication,
                    clientID: clientID
                )
                return durableSuccess(
                    commandID: commandID,
                    command: command,
                    identity: identity,
                    clientAttached: true,
                    lifecycleState: "running"
                )
            case .durableSessionStatus:
                let status = try durableRegistry.status(
                    authentication: authentication,
                    clientID: clientID
                )
                return durableSuccess(
                    commandID: commandID,
                    command: command,
                    identity: status.identity,
                    clientAttached: status.clientAttached,
                    lifecycleState: status.processRunning ? "running" : "terminal"
                )
            case .attachDurableSession:
                let handle = try durableRegistry.attach(
                    authentication: authentication,
                    clientID: clientID
                )
                let snapshot = Phase2ShellBrokerLifecycleSnapshot(
                    sessionID: handle.identity.sessionID,
                    state: .running(
                        requestID: handle.identity.launchRequest.requestID,
                        processIdentifier: handle.lease.ownedProcess.processIdentifier
                    ),
                    launchPlan: handle.lease.plan,
                    ownedProcess: handle.lease.ownedProcess,
                    cleanupProof: nil,
                    issues: []
                )
                lock.withLock {
                    sessions[handle.identity.sessionID] = SessionRecord(
                        snapshot: snapshot,
                        lease: handle.lease,
                        nextTranscriptSequence: durableRegistry.nextTranscriptSequence(
                            sessionID: handle.identity.sessionID
                        ) ?? 1,
                        transcriptLimits: handle.lease.plan.transcriptLimits
                    )
                    durableSessionIDs.insert(handle.identity.sessionID)
                }
                return durableSuccess(
                    commandID: commandID,
                    command: command,
                    identity: handle.identity,
                    clientAttached: true,
                    lifecycleState: handle.lease.isRunning ? "running" : "terminal"
                )
            case .detachDurableSession:
                let identity = try durableRegistry.detach(
                    authentication: authentication,
                    clientID: clientID
                )
                lock.withLock {
                    sessions.removeValue(forKey: identity.sessionID)
                    durableSessionIDs.remove(identity.sessionID)
                }
                return durableSuccess(
                    commandID: commandID,
                    command: command,
                    identity: identity,
                    clientAttached: false,
                    lifecycleState: "detached"
                )
            case .heartbeatDurableSession:
                let identity = try durableRegistry.heartbeat(
                    authentication: authentication,
                    clientID: clientID
                )
                return durableSuccess(
                    commandID: commandID,
                    command: command,
                    identity: identity,
                    clientAttached: true,
                    lifecycleState: "running"
                )
            default:
                return durableAuthenticationFailure(commandID: commandID, command: command)
            }
        } catch {
            return durableAuthenticationFailure(commandID: commandID, command: command)
        }
    }

    private func durableSuccess(
        commandID: UUID,
        command: Phase2ShellBrokerCommandKind,
        identity: Phase2DurableShellBrokerIdentity,
        clientAttached: Bool,
        lifecycleState: String
    ) -> Phase2ShellBrokerCommandResponse {
        Phase2ShellBrokerCommandResponse(
            commandID: commandID,
            command: command,
            status: .accepted,
            sessionID: identity.sessionID,
            requestID: identity.launchRequest.requestID,
            lifecycleState: lifecycleState,
            processIdentifier: identity.processIdentity.processIdentifier,
            executablePath: identity.processIdentity.executablePath,
            nextTranscriptSequence: durableRegistry.nextTranscriptSequence(sessionID: identity.sessionID),
            durableIdentity: identity,
            durableClientAttached: clientAttached
        )
    }

    private func durableAuthenticationFailure(
        commandID: UUID,
        command: Phase2ShellBrokerCommandKind
    ) -> Phase2ShellBrokerCommandResponse {
        Phase2ShellBrokerCommandResponse(
            commandID: commandID,
            command: command,
            status: .rejected,
            issues: ["durableAuthenticationRejected"]
        )
    }

    private func handleLaunch(
        commandID: UUID,
        request: Phase2ShellBrokerLaunchProcessRequest
    ) -> Phase2ShellBrokerCommandResponse {
        let plan = Phase2HumanPTYLaunchPlan(
            sessionID: request.sessionID,
            requestID: request.requestID,
            executablePath: request.executablePath,
            arguments: request.arguments,
            environment: request.environment,
            workingDirectoryPath: request.workingDirectoryPath,
            initialSize: Phase2HumanPTYTerminalSize(columns: request.columns, rows: request.rows),
            transcriptLimits: Phase2HumanPTYTranscriptLimits(
                maximumEvents: request.maximumTranscriptEvents,
                maximumEventBytes: request.maximumTranscriptEventBytes,
                maximumCumulativeBytes: request.maximumTranscriptCumulativeBytes
            )
        )
        if let existingRecord = lock.withLock({ sessions[plan.sessionID] }),
           let existingLease = existingRecord.lease,
           existingLease.isRunning {
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .launchProcess,
                status: .rejected,
                sessionID: plan.sessionID,
                requestID: plan.requestID,
                lifecycleState: String(describing: existingRecord.snapshot.state),
                processIdentifier: existingLease.ownedProcess.processIdentifier,
                executablePath: existingLease.ownedProcess.executablePath,
                issues: [
                    String(describing: Phase2ShellBrokerLifecycleIssue.transitionNotAllowed(
                        state: existingRecord.snapshot.state,
                        attempted: .prepareLaunch
                    ))
                ]
            )
        }

        var snapshot = Phase2ShellBrokerLifecycleSnapshot.initial(sessionID: plan.sessionID)
        snapshot = Phase2ShellBrokerLifecycleReducer.prepareLaunch(snapshot, plan: plan)
        guard snapshot.issues.isEmpty else {
            lock.withLock {
                sessions[plan.sessionID] = SessionRecord(snapshot: snapshot, lease: nil)
            }
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .launchProcess,
                status: .rejected,
                sessionID: plan.sessionID,
                requestID: plan.requestID,
                lifecycleState: String(describing: snapshot.state),
                issues: snapshot.issues.map(String.init(describing:))
            )
        }

        do {
            let lease = try processAdapter.launch(plan)
            snapshot = Phase2ShellBrokerLifecycleReducer.publishRunningProcess(snapshot, process: lease.ownedProcess)
            guard snapshot.issues.isEmpty else {
                let proof = lease.cleanup(outcome: .outcomeUnknown, timeout: 1.0)
                snapshot = Phase2ShellBrokerLifecycleReducer.requestCleanup(snapshot, reason: .launchFailure)
                snapshot = Phase2ShellBrokerLifecycleReducer.completeCleanup(snapshot, proof: proof)
                lock.withLock {
                    sessions[plan.sessionID] = SessionRecord(snapshot: snapshot, lease: nil)
                }
                return Phase2ShellBrokerCommandResponse(
                    commandID: commandID,
                    command: .launchProcess,
                    status: .failed,
                    sessionID: plan.sessionID,
                    requestID: plan.requestID,
                    lifecycleState: String(describing: snapshot.state),
                    issues: snapshot.issues.map(String.init(describing:))
                )
            }

            lock.withLock {
                sessions[plan.sessionID] = SessionRecord(
                    snapshot: snapshot,
                    lease: lease,
                    transcriptLimits: plan.transcriptLimits
                )
            }
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .launchProcess,
                status: .accepted,
                sessionID: plan.sessionID,
                requestID: plan.requestID,
                lifecycleState: String(describing: snapshot.state),
                processIdentifier: lease.ownedProcess.processIdentifier,
                executablePath: lease.ownedProcess.executablePath
            )
        } catch {
            snapshot = Phase2ShellBrokerLifecycleReducer.rejectLaunch(
                snapshot,
                requestID: plan.requestID,
                reason: String(describing: error)
            )
            lock.withLock {
                sessions[plan.sessionID] = SessionRecord(snapshot: snapshot, lease: nil)
            }
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .launchProcess,
                status: .failed,
                sessionID: plan.sessionID,
                requestID: plan.requestID,
                lifecycleState: String(describing: snapshot.state),
                issues: ["launchFailed: \(error)"]
            )
        }
    }

    private func handleCleanup(
        commandID: UUID,
        request: Phase2ShellBrokerCleanupProcessRequest
    ) -> Phase2ShellBrokerCommandResponse {
        let record = lock.withLock {
            sessions[request.sessionID]
        }
        guard var record, let lease = record.lease else {
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .cleanupProcess,
                status: .rejected,
                sessionID: request.sessionID,
                requestID: request.requestID,
                issues: ["noRunningLease"]
            )
        }
        guard lease.ownedProcess.requestID == request.requestID else {
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .cleanupProcess,
                status: .rejected,
                sessionID: request.sessionID,
                requestID: request.requestID,
                processIdentifier: lease.ownedProcess.processIdentifier,
                issues: [
                    "requestMismatch(expected: \(lease.ownedProcess.requestID), actual: \(request.requestID))"
                ]
            )
        }

        record.snapshot = Phase2ShellBrokerLifecycleReducer.requestCleanup(
            record.snapshot,
            reason: Phase2ShellBrokerCleanupReason(rawValue: request.reason) ?? .userCancel
        )
        guard record.snapshot.issues.isEmpty else {
            lock.withLock {
                sessions[request.sessionID] = record
            }
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .cleanupProcess,
                status: .rejected,
                sessionID: request.sessionID,
                requestID: request.requestID,
                lifecycleState: String(describing: record.snapshot.state),
                processIdentifier: lease.ownedProcess.processIdentifier,
                issues: record.snapshot.issues.map(String.init(describing:))
            )
        }

        let proof = lease.cleanup(outcome: .canceled)
        record.snapshot = Phase2ShellBrokerLifecycleReducer.completeCleanup(record.snapshot, proof: proof)
        record.lease = nil

        lock.withLock {
            sessions[request.sessionID] = record
        }

        return Phase2ShellBrokerCommandResponse(
            commandID: commandID,
            command: .cleanupProcess,
            status: record.snapshot.issues.isEmpty ? .accepted : .failed,
            sessionID: request.sessionID,
            requestID: request.requestID,
            lifecycleState: String(describing: record.snapshot.state),
            processIdentifier: proof.processIdentifier,
            observedProcessAbsent: proof.observedProcessAbsent,
            outcome: String(describing: proof.outcome),
            issues: record.snapshot.issues.map(String.init(describing:))
        )
    }

    private func handleWriteInput(
        commandID: UUID,
        request: Phase2ShellBrokerWriteInputRequest
    ) -> Phase2ShellBrokerCommandResponse {
        let validation = Phase2HumanPTYBrokerCommandValidator.validate(
            Phase2HumanPTYBrokerCommand(
                commandID: commandID,
                sessionID: request.sessionID,
                authority: .human,
                payload: .writeInput(request.bytes)
            ),
            expectedSessionID: request.sessionID
        )
        guard validation.isAccepted else {
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .writeInput,
                status: .rejected,
                sessionID: request.sessionID,
                requestID: request.requestID,
                issues: validation.issues.map(String.init(describing:))
            )
        }

        let lookup = lookupRunningLease(
            commandID: commandID,
            command: .writeInput,
            sessionID: request.sessionID,
            requestID: request.requestID
        )
        guard lookup.response == nil, let lease = lookup.lease else {
            return lookup.response!
        }

        do {
            let bytesWritten: Int
#if TESTING_SHELL_BROKER_PRINCIPAL
            bytesWritten = try writeInputForTesting?(lease, request.bytes) ?? lease.writeInput(request.bytes)
#else
            bytesWritten = try lease.writeInput(request.bytes)
#endif
            let event = appendTranscriptEvent(
                sessionID: request.sessionID,
                source: .human,
                payload: .input(request.bytes)
            )
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .writeInput,
                status: .accepted,
                sessionID: request.sessionID,
                requestID: request.requestID,
                processIdentifier: lease.ownedProcess.processIdentifier,
                bytesWritten: bytesWritten,
                transcriptEvents: [Phase2ShellBrokerTranscriptEventWire(event: event)],
                nextTranscriptSequence: event.sequence &+ 1
            )
        } catch {
            // A nonblocking write can have delivered a prefix before EAGAIN or a
            // terminal error. Preserve that irreversible side effect in both the
            // transcript and receipt; cached command replay must never write it twice.
            let bytesWritten: Int
            let retryable: Bool
            if case Phase2ShellBrokerPTYAllocation.IOError.writeFailed(let code, let count) = error {
                bytesWritten = min(max(count, 0), request.bytes.count)
                retryable = code == EAGAIN || code == EWOULDBLOCK
            } else {
                bytesWritten = 0
                retryable = false
            }
            let event = bytesWritten > 0 ? appendTranscriptEvent(
                sessionID: request.sessionID,
                source: .human,
                payload: .input(Array(request.bytes.prefix(bytesWritten)))
            ) : nil
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .writeInput,
                status: retryable ? .partial : .failed,
                sessionID: request.sessionID,
                requestID: request.requestID,
                processIdentifier: lease.ownedProcess.processIdentifier,
                bytesWritten: bytesWritten,
                transcriptEvents: event.map { [Phase2ShellBrokerTranscriptEventWire(event: $0)] } ?? [],
                nextTranscriptSequence: event.map { $0.sequence &+ 1 },
                issues: retryable ? [] : ["writeInputFailed: \(error)"]
            )
        }
    }

    private func handleResize(
        commandID: UUID,
        request: Phase2ShellBrokerResizeTerminalRequest
    ) -> Phase2ShellBrokerCommandResponse {
        let size = Phase2HumanPTYTerminalSize(columns: request.columns, rows: request.rows)
        let validation = Phase2HumanPTYBrokerCommandValidator.validate(
            Phase2HumanPTYBrokerCommand(
                commandID: commandID,
                sessionID: request.sessionID,
                authority: .human,
                payload: .resize(size)
            ),
            expectedSessionID: request.sessionID
        )
        guard validation.isAccepted else {
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .resizeTerminal,
                status: .rejected,
                sessionID: request.sessionID,
                requestID: request.requestID,
                issues: validation.issues.map(String.init(describing:))
            )
        }

        let lookup = lookupRunningLease(
            commandID: commandID,
            command: .resizeTerminal,
            sessionID: request.sessionID,
            requestID: request.requestID
        )
        guard lookup.response == nil, let lease = lookup.lease else {
            return lookup.response!
        }

        do {
            try lease.resizeTerminal(size)
            let event = appendTranscriptEvent(
                sessionID: request.sessionID,
                source: .human,
                payload: .resize(columns: request.columns, rows: request.rows)
            )
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .resizeTerminal,
                status: .accepted,
                sessionID: request.sessionID,
                requestID: request.requestID,
                processIdentifier: lease.ownedProcess.processIdentifier,
                transcriptEvents: [Phase2ShellBrokerTranscriptEventWire(event: event)],
                nextTranscriptSequence: event.sequence &+ 1
            )
        } catch {
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .resizeTerminal,
                status: .failed,
                sessionID: request.sessionID,
                requestID: request.requestID,
                processIdentifier: lease.ownedProcess.processIdentifier,
                issues: ["resizeFailed: \(error)"]
            )
        }
    }

    private func handleSignal(
        commandID: UUID,
        request: Phase2ShellBrokerSendSignalRequest
    ) -> Phase2ShellBrokerCommandResponse {
        let validation = Phase2HumanPTYBrokerCommandValidator.validate(
            Phase2HumanPTYBrokerCommand(
                commandID: commandID,
                sessionID: request.sessionID,
                authority: .human,
                payload: .signal(request.signal)
            ),
            expectedSessionID: request.sessionID
        )
        guard validation.isAccepted else {
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .sendSignal,
                status: .rejected,
                sessionID: request.sessionID,
                requestID: request.requestID,
                issues: validation.issues.map(String.init(describing:))
            )
        }

        let lookup = lookupRunningLease(
            commandID: commandID,
            command: .sendSignal,
            sessionID: request.sessionID,
            requestID: request.requestID
        )
        guard lookup.response == nil, let lease = lookup.lease else {
            return lookup.response!
        }

        do {
            try lease.sendSignal(request.signal)
            let event = appendTranscriptEvent(
                sessionID: request.sessionID,
                source: .human,
                payload: .signal(request.signal)
            )
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .sendSignal,
                status: .accepted,
                sessionID: request.sessionID,
                requestID: request.requestID,
                processIdentifier: lease.ownedProcess.processIdentifier,
                transcriptEvents: [Phase2ShellBrokerTranscriptEventWire(event: event)],
                nextTranscriptSequence: event.sequence &+ 1
            )
        } catch {
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .sendSignal,
                status: .failed,
                sessionID: request.sessionID,
                requestID: request.requestID,
                processIdentifier: lease.ownedProcess.processIdentifier,
                issues: ["signalFailed: \(error)"]
            )
        }
    }

    private func handlePollTranscript(
        commandID: UUID,
        request: Phase2ShellBrokerPollTranscriptRequest
    ) -> Phase2ShellBrokerCommandResponse {
        guard request.maximumEvents > 0, request.maximumBytes > 0, request.timeoutMilliseconds >= 0 else {
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .pollTranscript,
                status: .rejected,
                sessionID: request.sessionID,
                requestID: request.requestID,
                issues: ["invalidPollRequest"]
            )
        }

        let lookup = lookupLease(
            commandID: commandID,
            command: .pollTranscript,
            sessionID: request.sessionID,
            requestID: request.requestID
        )
        guard lookup.response == nil, let lease = lookup.lease else {
            return lookup.response!
        }

        let isDurable = lock.withLock { durableSessionIDs.contains(request.sessionID) }
        if !isDurable {
            let outputBytes = lease.readAvailablePTYOutput(
                maxBytes: min(request.maximumBytes, lease.plan.transcriptLimits.maximumEventBytes, 16 * 1_024),
                timeout: TimeInterval(min(request.timeoutMilliseconds, 500)) / 1_000
            )
            if !outputBytes.isEmpty {
                _ = appendTranscriptEvent(
                    sessionID: request.sessionID,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: outputBytes)
                )
            }
            if let outcome = lease.observedTerminalOutcomeIfExited {
                _ = appendTerminalTranscriptEventIfNeeded(sessionID: request.sessionID, outcome: outcome)
                releaseLeaseAfterObservedExit(sessionID: request.sessionID, lease: lease)
            }
        }

        let events = selectedTranscriptEvents(
            sessionID: request.sessionID,
            afterSequence: request.afterSequence,
            maximumEvents: request.maximumEvents,
            maximumBytes: request.maximumBytes
        )

        return Phase2ShellBrokerCommandResponse(
            commandID: commandID,
            command: .pollTranscript,
            status: .accepted,
            sessionID: request.sessionID,
            requestID: request.requestID,
            processIdentifier: lease.ownedProcess.processIdentifier,
            transcriptEvents: events.map(Phase2ShellBrokerTranscriptEventWire.init(event:)),
            nextTranscriptSequence: currentNextTranscriptSequence(sessionID: request.sessionID)
        )
    }

    private func handleReconnect(
        commandID: UUID,
        request: Phase2ShellBrokerReconnectSessionRequest
    ) -> Phase2ShellBrokerCommandResponse {
        guard request.maximumEvents > 0, request.maximumBytes > 0 else {
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .reconnectSession,
                status: .rejected,
                sessionID: request.sessionID,
                requestID: request.requestID,
                issues: ["invalidReconnectRequest"]
            )
        }

        let validation = Phase2HumanPTYBrokerCommandValidator.validate(
            Phase2HumanPTYBrokerCommand(
                commandID: commandID,
                sessionID: request.sessionID,
                authority: .app,
                payload: .reconnect(reconnectID: request.reconnectID)
            ),
            expectedSessionID: request.sessionID
        )
        guard validation.isAccepted else {
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .reconnectSession,
                status: .rejected,
                sessionID: request.sessionID,
                requestID: request.requestID,
                issues: validation.issues.map(String.init(describing:))
            )
        }

        let lookup = lookupLease(
            commandID: commandID,
            command: .reconnectSession,
            sessionID: request.sessionID,
            requestID: request.requestID
        )
        guard lookup.response == nil, let lease = lookup.lease else {
            return lookup.response!
        }
        guard lease.isRunning else {
            if let outcome = lease.observedTerminalOutcomeIfExited {
                _ = appendTerminalTranscriptEventIfNeeded(sessionID: request.sessionID, outcome: outcome)
                releaseLeaseAfterObservedExit(sessionID: request.sessionID, lease: lease)
                let events = selectedTranscriptEvents(
                    sessionID: request.sessionID,
                    afterSequence: request.afterSequence,
                    maximumEvents: request.maximumEvents,
                    maximumBytes: request.maximumBytes
                )
                return Phase2ShellBrokerCommandResponse(
                    commandID: commandID,
                    command: .reconnectSession,
                    status: .accepted,
                    sessionID: request.sessionID,
                    requestID: request.requestID,
                    processIdentifier: lease.ownedProcess.processIdentifier,
                    transcriptEvents: events.map(Phase2ShellBrokerTranscriptEventWire.init(event:)),
                    nextTranscriptSequence: currentNextTranscriptSequence(sessionID: request.sessionID)
                )
            }
            return Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: .reconnectSession,
                status: .rejected,
                sessionID: request.sessionID,
                requestID: request.requestID,
                processIdentifier: lease.ownedProcess.processIdentifier,
                issues: ["processNotRunning"]
            )
        }

        let reconnectEvent = appendTranscriptEvent(
            sessionID: request.sessionID,
            source: .app,
            payload: .reconnect(reconnectID: request.reconnectID)
        )
        let events = selectedTranscriptEvents(
            sessionID: request.sessionID,
            afterSequence: request.afterSequence,
            maximumEvents: request.maximumEvents,
            maximumBytes: request.maximumBytes
        )

        return Phase2ShellBrokerCommandResponse(
            commandID: commandID,
            command: .reconnectSession,
            status: .accepted,
            sessionID: request.sessionID,
            requestID: request.requestID,
            processIdentifier: lease.ownedProcess.processIdentifier,
            transcriptEvents: events.map(Phase2ShellBrokerTranscriptEventWire.init(event:)),
            nextTranscriptSequence: reconnectEvent.sequence &+ 1
        )
    }

    private func appendTerminalTranscriptEventIfNeeded(
        sessionID: UUID,
        outcome: Phase2HumanPTYTerminalOutcome
    ) -> Phase2HumanPTYTranscriptEvent? {
        if lock.withLock({ durableSessionIDs.contains(sessionID) }) {
            return try? durableRegistry.appendTerminalTranscriptEventIfNeeded(
                sessionID: sessionID,
                outcome: outcome
            )
        }
        return lock.withLock { () -> Phase2HumanPTYTranscriptEvent? in
            guard var record = sessions[sessionID] else { return nil }
            if record.transcriptEvents.contains(where: { event in
                if case .terminal = event.payload {
                    return true
                }
                return false
            }) {
                return nil
            }

            let sequence = record.nextTranscriptSequence
            let event = Phase2HumanPTYTranscriptEvent(
                sessionID: sessionID,
                sequence: sequence,
                source: .broker,
                payload: .terminal(outcome)
            )
            record.transcriptEvents.append(event)
            record.nextTranscriptSequence = sequence &+ 1
            compactTranscriptEventsIfNeeded(&record, sessionID: sessionID)
            sessions[sessionID] = record
            return event
        }
    }

    private func releaseLeaseAfterObservedExit(
        sessionID: UUID,
        lease: Phase2ShellBrokerProcessLease
    ) {
        lease.closePTYAfterObservedExit()
        return lock.withLock {
            guard var record = sessions[sessionID],
                  record.lease?.ownedProcess.processIdentifier == lease.ownedProcess.processIdentifier
            else { return }
            record.lease = nil
            sessions[sessionID] = record
        }
    }

    private func lookupRunningLease(
        commandID: UUID,
        command: Phase2ShellBrokerCommandKind,
        sessionID: UUID,
        requestID: UUID
    ) -> (lease: Phase2ShellBrokerProcessLease?, response: Phase2ShellBrokerCommandResponse?) {
        let lookup = lookupLease(commandID: commandID, command: command, sessionID: sessionID, requestID: requestID)
        guard lookup.response == nil, let lease = lookup.lease else { return lookup }
        guard lease.isRunning else {
            return (nil, Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: command,
                status: .rejected,
                sessionID: sessionID,
                requestID: requestID,
                processIdentifier: lease.ownedProcess.processIdentifier,
                issues: ["processNotRunning"]
            ))
        }
        return lookup
    }

    private func lookupLease(
        commandID: UUID,
        command: Phase2ShellBrokerCommandKind,
        sessionID: UUID,
        requestID: UUID
    ) -> (lease: Phase2ShellBrokerProcessLease?, response: Phase2ShellBrokerCommandResponse?) {
        let record = lock.withLock { sessions[sessionID] }
        guard let record, let lease = record.lease else {
            return (nil, Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: command,
                status: .rejected,
                sessionID: sessionID,
                requestID: requestID,
                issues: ["noRunningLease"]
            ))
        }
        guard lease.ownedProcess.requestID == requestID else {
            return (nil, Phase2ShellBrokerCommandResponse(
                commandID: commandID,
                command: command,
                status: .rejected,
                sessionID: sessionID,
                requestID: requestID,
                processIdentifier: lease.ownedProcess.processIdentifier,
                issues: [
                    "requestMismatch(expected: \(lease.ownedProcess.requestID), actual: \(requestID))"
                ]
            ))
        }
        return (lease, nil)
    }

    private func appendTranscriptEvent(
        sessionID: UUID,
        source: Phase2HumanPTYEventSource,
        payload: Phase2HumanPTYEventPayload
    ) -> Phase2HumanPTYTranscriptEvent {
        if lock.withLock({ durableSessionIDs.contains(sessionID) }),
           let event = try? durableRegistry.appendTranscriptEvent(
               sessionID: sessionID,
               source: source,
               payload: payload
           ) {
            return event
        }
        return lock.withLock {
            var record = sessions[sessionID]
            let sequence = record?.nextTranscriptSequence ?? 1
            let event = Phase2HumanPTYTranscriptEvent(
                sessionID: sessionID,
                sequence: sequence,
                source: source,
                payload: payload
            )
            record?.transcriptEvents.append(event)
            record?.nextTranscriptSequence = sequence &+ 1
            if var record {
                compactTranscriptEventsIfNeeded(&record, sessionID: sessionID)
                sessions[sessionID] = record
            }
            return event
        }
    }

    private func compactTranscriptEventsIfNeeded(
        _ record: inout SessionRecord,
        sessionID: UUID
    ) {
        let limits = record.transcriptLimits
        guard limits.isValid else { return }

        let cumulativeBytes = record.transcriptEvents.reduce(0) { partial, event in
            partial + event.payload.byteCount
        }
        guard record.transcriptEvents.count > limits.maximumEvents ||
            cumulativeBytes > limits.maximumCumulativeBytes
        else {
            return
        }

        let retainedBudget = max(1, limits.maximumEvents - 1)
        var retainedReversed: [Phase2HumanPTYTranscriptEvent] = []
        var retainedBytes = 0
        for event in record.transcriptEvents.reversed() {
            guard retainedReversed.count < retainedBudget else { break }
            let eventBytes = event.payload.byteCount
            guard retainedBytes + eventBytes <= limits.maximumCumulativeBytes else { break }
            retainedReversed.append(event)
            retainedBytes += eventBytes
        }

        let retained = retainedReversed.reversed()

        let dropped: ArraySlice<Phase2HumanPTYTranscriptEvent>
        let gapSequence: UInt64
        if let firstRetained = retained.first {
            dropped = record.transcriptEvents.prefix { event in
                event.sequence < firstRetained.sequence
            }
            gapSequence = firstRetained.sequence > 1 ? firstRetained.sequence - 1 : firstRetained.sequence
        } else {
            dropped = record.transcriptEvents[...]
            gapSequence = record.nextTranscriptSequence > 1 ? record.nextTranscriptSequence - 1 : 1
        }
        guard !dropped.isEmpty else { return }

        let lostByteCount = dropped.reduce(0) { partial, event in
            if case .gap(_, let priorLostByteCount) = event.payload {
                return partial + priorLostByteCount
            }
            return partial + event.payload.byteCount
        }
        let gap = Phase2HumanPTYTranscriptEvent(
            sessionID: sessionID,
            sequence: gapSequence,
            source: .broker,
            payload: .gap(reason: .spoolLimitExceeded, lostByteCount: max(lostByteCount, dropped.count))
        )

        if limits.maximumEvents == 1 {
            record.transcriptEvents = [gap]
        } else {
            record.transcriptEvents = [gap] + retained
        }
    }

    private func selectedTranscriptEvents(
        sessionID: UUID,
        afterSequence: UInt64,
        maximumEvents: Int,
        maximumBytes: Int
    ) -> [Phase2HumanPTYTranscriptEvent] {
        if lock.withLock({ durableSessionIDs.contains(sessionID) }) {
            return (try? durableRegistry.transcriptSnapshot(
                sessionID: sessionID,
                afterSequence: afterSequence,
                maximumEvents: maximumEvents,
                maximumBytes: maximumBytes
            ).events) ?? []
        }
        return lock.withLock {
            guard let record = sessions[sessionID] else { return [] }
            var selected: [Phase2HumanPTYTranscriptEvent] = []
            var selectedBytes = 0
            for event in record.transcriptEvents where event.sequence > afterSequence {
                guard selected.count < maximumEvents else { break }
                let eventBytes = event.payload.byteCount
                guard selectedBytes + eventBytes <= maximumBytes else { break }
                selected.append(event)
                selectedBytes += eventBytes
            }
            return selected
        }
    }

    private func currentNextTranscriptSequence(sessionID: UUID) -> UInt64? {
        if lock.withLock({ durableSessionIDs.contains(sessionID) }) {
            return durableRegistry.nextTranscriptSequence(sessionID: sessionID)
        }
        return lock.withLock { sessions[sessionID]?.nextTranscriptSequence }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
