import Foundation
#if TESTING_SHELL_BROKER_PRINCIPAL
@testable import MacScope
#endif

/// The folder under which MacScope stages source execution, captures and test evidence.
/// Resolved from the MACSCOPE_WORK_ROOT environment variable (an absolute path); without
/// it, the current user's home directory. Every stage-root authority check uses the same
/// answer, so a stage outside this folder is refused.
enum MacScopeWorkRoot {
    static var path: String {
        if var value = ProcessInfo.processInfo.environment["MACSCOPE_WORK_ROOT"], value.hasPrefix("/") {
            while value.count > 1, value.hasSuffix("/") { value.removeLast() }
            return value
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    static var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// True only for paths strictly beneath the work root.
    static func contains(_ candidate: String) -> Bool {
        let root = path
        return candidate.hasPrefix(root == "/" ? "/" : root + "/")
    }
}

enum Phase2ShellBrokerProtocolIdentity {
    static let schemaVersion = 4
    static let serviceIdentifier = "terminal.human_pty.shell_broker"
    static let wireProtocol = "macscope.phase2.shell_broker.xpc.v4"
    static let embeddedServiceName = "org.macscope.app.ShellBroker"
    static let persistentMachServiceName = "org.macscope.app.ShellBroker.agent"
    static let maximumMessageBytes = 64 * 1024
}

struct Phase2ShellBrokerHandshake: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable {
        case boundaryReady
    }

    let schemaVersion: Int
    let serviceIdentifier: String
    let wireProtocol: String
    let status: Status
    let supportedCommands: [String]
    let maximumMessageBytes: Int
    let brokerIncarnationID: UUID?
    var sourceExecutionProtocol: String? = nil

    static var boundaryReady: Self {
        boundaryReady(brokerIncarnationID: nil)
    }

    static func boundaryReady(brokerIncarnationID: UUID?) -> Self {
        Self(
            schemaVersion: Phase2ShellBrokerProtocolIdentity.schemaVersion,
            serviceIdentifier: Phase2ShellBrokerProtocolIdentity.serviceIdentifier,
            wireProtocol: Phase2ShellBrokerProtocolIdentity.wireProtocol,
            status: .boundaryReady,
            supportedCommands: Phase2ShellBrokerCommandKind.allCases.map(\.rawValue),
            maximumMessageBytes: Phase2ShellBrokerProtocolIdentity.maximumMessageBytes,
            brokerIncarnationID: brokerIncarnationID,
            sourceExecutionProtocol: Phase2SourceExecutionWireCodec.protocolIdentity
        )
    }
}

enum Phase2ShellBrokerCommandKind: String, CaseIterable, Codable, Equatable, Sendable {
    case launchProcess
    case cleanupProcess
    case writeInput
    case resizeTerminal
    case sendSignal
    case pollTranscript
    case reconnectSession
    case launchDurableProcess
    case commitDurableSession
    case durableSessionStatus
    case attachDurableSession
    case detachDurableSession
    case heartbeatDurableSession
}

struct Phase2ShellBrokerDurableAuthenticationWire: Codable, Equatable, Sendable {
    let brokerIncarnationID: UUID
    let sessionID: UUID
    let capabilityID: UUID
    let capabilitySecretBytes: [UInt8]

    func makeAuthenticationRequest() throws -> Phase2DurableShellBrokerAuthenticationRequest {
        Phase2DurableShellBrokerAuthenticationRequest(
            brokerIncarnationID: brokerIncarnationID,
            sessionID: sessionID,
            capabilityID: capabilityID,
            capabilitySecret: try Phase2DurableShellBrokerCapabilitySecret(bytes: Data(capabilitySecretBytes))
        )
    }
}

struct Phase2ShellBrokerLaunchDurableProcessRequest: Codable, Equatable, Sendable {
    let launch: Phase2ShellBrokerLaunchProcessRequest
    let durableLaunch: Phase2DurableShellBrokerLaunchRequest
    let capabilitySecretBytes: [UInt8]
}

struct Phase2ShellBrokerDurableSessionRequest: Codable, Equatable, Sendable {
    let authentication: Phase2ShellBrokerDurableAuthenticationWire
}

struct Phase2ShellBrokerCommandRequest: Codable, Equatable, Sendable {
    let commandID: UUID
    let command: Phase2ShellBrokerCommandKind
    let payload: Data

    init(
        commandID: UUID,
        command: Phase2ShellBrokerCommandKind,
        payload: Data
    ) {
        self.commandID = commandID
        self.command = command
        self.payload = payload
    }
}

struct Phase2ShellBrokerLaunchProcessRequest: Codable, Equatable, Sendable {
    let sessionID: UUID
    let requestID: UUID
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryPath: String?
    let columns: Int
    let rows: Int
    let maximumTranscriptEvents: Int
    let maximumTranscriptEventBytes: Int
    let maximumTranscriptCumulativeBytes: Int

    init(
        sessionID: UUID,
        requestID: UUID,
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectoryPath: String? = nil,
        columns: Int = 120,
        rows: Int = 32,
        maximumTranscriptEvents: Int = 1_024,
        maximumTranscriptEventBytes: Int = 65_536,
        maximumTranscriptCumulativeBytes: Int = 4 * 1_024 * 1_024
    ) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryPath = workingDirectoryPath
        self.columns = columns
        self.rows = rows
        self.maximumTranscriptEvents = maximumTranscriptEvents
        self.maximumTranscriptEventBytes = maximumTranscriptEventBytes
        self.maximumTranscriptCumulativeBytes = maximumTranscriptCumulativeBytes
    }
}

struct Phase2ShellBrokerCleanupProcessRequest: Codable, Equatable, Sendable {
    let sessionID: UUID
    let requestID: UUID
    let reason: String

    init(
        sessionID: UUID,
        requestID: UUID,
        reason: String = "userCancel"
    ) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.reason = reason
    }
}

struct Phase2ShellBrokerWriteInputRequest: Codable, Equatable, Sendable {
    let sessionID: UUID
    let requestID: UUID
    let bytes: [UInt8]

    init(sessionID: UUID, requestID: UUID, bytes: [UInt8]) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.bytes = bytes
    }
}

struct Phase2ShellBrokerResizeTerminalRequest: Codable, Equatable, Sendable {
    let sessionID: UUID
    let requestID: UUID
    let columns: Int
    let rows: Int

    init(sessionID: UUID, requestID: UUID, columns: Int, rows: Int) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.columns = columns
        self.rows = rows
    }
}

struct Phase2ShellBrokerSendSignalRequest: Codable, Equatable, Sendable {
    let sessionID: UUID
    let requestID: UUID
    let signal: Phase2HumanPTYSignal

    init(sessionID: UUID, requestID: UUID, signal: Phase2HumanPTYSignal) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.signal = signal
    }
}

struct Phase2ShellBrokerPollTranscriptRequest: Codable, Equatable, Sendable {
    let sessionID: UUID
    let requestID: UUID
    let afterSequence: UInt64
    let maximumEvents: Int
    let maximumBytes: Int
    let timeoutMilliseconds: Int

    init(
        sessionID: UUID,
        requestID: UUID,
        afterSequence: UInt64 = 0,
        maximumEvents: Int = 32,
        maximumBytes: Int = 4_096,
        timeoutMilliseconds: Int = 50
    ) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.afterSequence = afterSequence
        self.maximumEvents = maximumEvents
        self.maximumBytes = maximumBytes
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}

struct Phase2ShellBrokerReconnectSessionRequest: Codable, Equatable, Sendable {
    let sessionID: UUID
    let requestID: UUID
    let reconnectID: UUID
    let afterSequence: UInt64
    let maximumEvents: Int
    let maximumBytes: Int

    init(
        sessionID: UUID,
        requestID: UUID,
        reconnectID: UUID,
        afterSequence: UInt64 = 0,
        maximumEvents: Int = 64,
        maximumBytes: Int = 8_192
    ) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.reconnectID = reconnectID
        self.afterSequence = afterSequence
        self.maximumEvents = maximumEvents
        self.maximumBytes = maximumBytes
    }
}

struct Phase2ShellBrokerTranscriptEventWire: Codable, Equatable, Sendable {
    let sessionID: UUID
    let sequence: UInt64
    let source: Phase2HumanPTYEventSource
    let payloadKind: Phase2HumanPTYEventPayloadKind
    let bytes: [UInt8]?
    let outputStream: Phase2HumanPTYOutputStream?
    let columns: Int?
    let rows: Int?
    let signal: Phase2HumanPTYSignal?
    let reconnectID: UUID?
    let gapReason: Phase2HumanPTYGapReason?
    let lostByteCount: Int?
    let terminalOutcome: String?
    let terminalStatus: Int32?

    init(event: Phase2HumanPTYTranscriptEvent) {
        sessionID = event.sessionID
        sequence = event.sequence
        source = event.source
        payloadKind = event.payload.kind

        switch event.payload {
        case .input(let eventBytes):
            bytes = eventBytes
            outputStream = nil
            columns = nil
            rows = nil
            signal = nil
            reconnectID = nil
            gapReason = nil
            lostByteCount = nil
            terminalOutcome = nil
            terminalStatus = nil
        case .output(let stream, let eventBytes):
            bytes = eventBytes
            outputStream = stream
            columns = nil
            rows = nil
            signal = nil
            reconnectID = nil
            gapReason = nil
            lostByteCount = nil
            terminalOutcome = nil
            terminalStatus = nil
        case .resize(let eventColumns, let eventRows):
            bytes = nil
            outputStream = nil
            columns = eventColumns
            rows = eventRows
            signal = nil
            reconnectID = nil
            gapReason = nil
            lostByteCount = nil
            terminalOutcome = nil
            terminalStatus = nil
        case .signal(let eventSignal):
            bytes = nil
            outputStream = nil
            columns = nil
            rows = nil
            signal = eventSignal
            reconnectID = nil
            gapReason = nil
            lostByteCount = nil
            terminalOutcome = nil
            terminalStatus = nil
        case .reconnect(let eventReconnectID):
            bytes = nil
            outputStream = nil
            columns = nil
            rows = nil
            signal = nil
            reconnectID = eventReconnectID
            gapReason = nil
            lostByteCount = nil
            terminalOutcome = nil
            terminalStatus = nil
        case .gap(let reason, let eventLostByteCount):
            bytes = nil
            outputStream = nil
            columns = nil
            rows = nil
            signal = nil
            reconnectID = nil
            gapReason = reason
            lostByteCount = eventLostByteCount
            terminalOutcome = nil
            terminalStatus = nil
        case .terminal(let outcome):
            bytes = nil
            outputStream = nil
            columns = nil
            rows = nil
            signal = nil
            reconnectID = nil
            gapReason = nil
            lostByteCount = nil
            switch outcome {
            case .exited(let status):
                terminalOutcome = "exited"
                terminalStatus = status
            case .signaled(let eventSignal):
                terminalOutcome = "signaled:\(eventSignal.rawValue)"
                terminalStatus = nil
            case .canceled:
                terminalOutcome = "canceled"
                terminalStatus = nil
            case .interrupted:
                terminalOutcome = "interrupted"
                terminalStatus = nil
            case .brokerCrashed:
                terminalOutcome = "brokerCrashed"
                terminalStatus = nil
            case .outcomeUnknown:
                terminalOutcome = "outcomeUnknown"
                terminalStatus = nil
            }
        }
    }

    func makeEvent() -> Phase2HumanPTYTranscriptEvent? {
        let payload: Phase2HumanPTYEventPayload?
        switch payloadKind {
        case .input:
            payload = bytes.map { .input($0) }
        case .output:
            if let outputStream, let bytes {
                payload = .output(stream: outputStream, bytes: bytes)
            } else {
                payload = nil
            }
        case .resize:
            if let columns, let rows {
                payload = .resize(columns: columns, rows: rows)
            } else {
                payload = nil
            }
        case .signal:
            payload = signal.map { .signal($0) }
        case .reconnect:
            payload = reconnectID.map { .reconnect(reconnectID: $0) }
        case .gap:
            if let gapReason, let lostByteCount {
                payload = .gap(reason: gapReason, lostByteCount: lostByteCount)
            } else {
                payload = nil
            }
        case .terminal:
            switch terminalOutcome {
            case "exited":
                payload = .terminal(.exited(status: terminalStatus ?? 0))
            case "canceled":
                payload = .terminal(.canceled)
            case "interrupted":
                payload = .terminal(.interrupted)
            case "brokerCrashed":
                payload = .terminal(.brokerCrashed)
            case "outcomeUnknown":
                payload = .terminal(.outcomeUnknown)
            case let value? where value.hasPrefix("signaled:"):
                let rawSignal = String(value.dropFirst("signaled:".count))
                if let signal = Phase2HumanPTYSignal(rawValue: rawSignal) {
                    payload = .terminal(.signaled(signal))
                } else {
                    payload = nil
                }
            default:
                payload = nil
            }
        }

        guard let payload else { return nil }
        return Phase2HumanPTYTranscriptEvent(
            sessionID: sessionID,
            sequence: sequence,
            source: source,
            payload: payload
        )
    }
}

struct Phase2ShellBrokerCommandResponse: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable {
        case accepted
        /// An input prefix was delivered; only the remainder may be sent again.
        case partial
        case rejected
        case failed
        case invalid
    }

    let commandID: UUID?
    let command: Phase2ShellBrokerCommandKind?
    let status: Status
    let sessionID: UUID?
    let requestID: UUID?
    let lifecycleState: String?
    let processIdentifier: Int32?
    let executablePath: String?
    let observedProcessAbsent: Bool?
    let outcome: String?
    let bytesWritten: Int?
    let transcriptEvents: [Phase2ShellBrokerTranscriptEventWire]
    let nextTranscriptSequence: UInt64?
    let issues: [String]
    let durableIdentity: Phase2DurableShellBrokerIdentity?
    let durableClientAttached: Bool?

    init(
        commandID: UUID?,
        command: Phase2ShellBrokerCommandKind?,
        status: Status,
        sessionID: UUID? = nil,
        requestID: UUID? = nil,
        lifecycleState: String? = nil,
        processIdentifier: Int32? = nil,
        executablePath: String? = nil,
        observedProcessAbsent: Bool? = nil,
        outcome: String? = nil,
        bytesWritten: Int? = nil,
        transcriptEvents: [Phase2ShellBrokerTranscriptEventWire] = [],
        nextTranscriptSequence: UInt64? = nil,
        issues: [String] = [],
        durableIdentity: Phase2DurableShellBrokerIdentity? = nil,
        durableClientAttached: Bool? = nil
    ) {
        self.commandID = commandID
        self.command = command
        self.status = status
        self.sessionID = sessionID
        self.requestID = requestID
        self.lifecycleState = lifecycleState
        self.processIdentifier = processIdentifier
        self.executablePath = executablePath
        self.observedProcessAbsent = observedProcessAbsent
        self.outcome = outcome
        self.bytesWritten = bytesWritten
        self.transcriptEvents = transcriptEvents
        self.nextTranscriptSequence = nextTranscriptSequence
        self.issues = issues
        self.durableIdentity = durableIdentity
        self.durableClientAttached = durableClientAttached
    }
}

enum Phase2ShellBrokerWireCodec {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    static func encodeHandshake(_ handshake: Phase2ShellBrokerHandshake) throws -> Data {
        try encoder.encode(handshake)
    }

    static func decodeHandshake(_ data: Data) throws -> Phase2ShellBrokerHandshake {
        try decoder.decode(Phase2ShellBrokerHandshake.self, from: data)
    }

    static func encodeCommandRequest(_ request: Phase2ShellBrokerCommandRequest) throws -> Data {
        try encoder.encode(request)
    }

    static func decodeCommandRequest(_ data: Data) throws -> Phase2ShellBrokerCommandRequest {
        try decoder.decode(Phase2ShellBrokerCommandRequest.self, from: data)
    }

    static func encodeLaunchProcessRequest(_ request: Phase2ShellBrokerLaunchProcessRequest) throws -> Data {
        try encoder.encode(request)
    }

    static func decodeLaunchProcessRequest(_ data: Data) throws -> Phase2ShellBrokerLaunchProcessRequest {
        try decoder.decode(Phase2ShellBrokerLaunchProcessRequest.self, from: data)
    }

    static func encodeCleanupProcessRequest(_ request: Phase2ShellBrokerCleanupProcessRequest) throws -> Data {
        try encoder.encode(request)
    }

    static func decodeCleanupProcessRequest(_ data: Data) throws -> Phase2ShellBrokerCleanupProcessRequest {
        try decoder.decode(Phase2ShellBrokerCleanupProcessRequest.self, from: data)
    }

    static func encodeWriteInputRequest(_ request: Phase2ShellBrokerWriteInputRequest) throws -> Data {
        try encoder.encode(request)
    }

    static func decodeWriteInputRequest(_ data: Data) throws -> Phase2ShellBrokerWriteInputRequest {
        try decoder.decode(Phase2ShellBrokerWriteInputRequest.self, from: data)
    }

    static func encodeResizeTerminalRequest(_ request: Phase2ShellBrokerResizeTerminalRequest) throws -> Data {
        try encoder.encode(request)
    }

    static func decodeResizeTerminalRequest(_ data: Data) throws -> Phase2ShellBrokerResizeTerminalRequest {
        try decoder.decode(Phase2ShellBrokerResizeTerminalRequest.self, from: data)
    }

    static func encodeSendSignalRequest(_ request: Phase2ShellBrokerSendSignalRequest) throws -> Data {
        try encoder.encode(request)
    }

    static func decodeSendSignalRequest(_ data: Data) throws -> Phase2ShellBrokerSendSignalRequest {
        try decoder.decode(Phase2ShellBrokerSendSignalRequest.self, from: data)
    }

    static func encodePollTranscriptRequest(_ request: Phase2ShellBrokerPollTranscriptRequest) throws -> Data {
        try encoder.encode(request)
    }

    static func decodePollTranscriptRequest(_ data: Data) throws -> Phase2ShellBrokerPollTranscriptRequest {
        try decoder.decode(Phase2ShellBrokerPollTranscriptRequest.self, from: data)
    }

    static func encodeReconnectSessionRequest(_ request: Phase2ShellBrokerReconnectSessionRequest) throws -> Data {
        try encoder.encode(request)
    }

    static func decodeReconnectSessionRequest(_ data: Data) throws -> Phase2ShellBrokerReconnectSessionRequest {
        try decoder.decode(Phase2ShellBrokerReconnectSessionRequest.self, from: data)
    }

    static func encodeLaunchDurableProcessRequest(_ request: Phase2ShellBrokerLaunchDurableProcessRequest) throws -> Data {
        try encoder.encode(request)
    }

    static func decodeLaunchDurableProcessRequest(_ data: Data) throws -> Phase2ShellBrokerLaunchDurableProcessRequest {
        try decoder.decode(Phase2ShellBrokerLaunchDurableProcessRequest.self, from: data)
    }

    static func encodeDurableSessionRequest(_ request: Phase2ShellBrokerDurableSessionRequest) throws -> Data {
        try encoder.encode(request)
    }

    static func decodeDurableSessionRequest(_ data: Data) throws -> Phase2ShellBrokerDurableSessionRequest {
        try decoder.decode(Phase2ShellBrokerDurableSessionRequest.self, from: data)
    }

    static func encodeCommandResponse(_ response: Phase2ShellBrokerCommandResponse) throws -> Data {
        try encoder.encode(response)
    }

    static func decodeCommandResponse(_ data: Data) throws -> Phase2ShellBrokerCommandResponse {
        try decoder.decode(Phase2ShellBrokerCommandResponse.self, from: data)
    }
}

enum Phase2ShellBrokerPeerRequirement {
    private static let certificate =
        "anchor apple generic and certificate leaf[subject.CN] = \"Apple Development: MacScope Developer (CERT000000)\" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"

    static let app = "identifier \"org.macscope.app\" and \(certificate)"
    static let broker = "identifier \"org.macscope.app.ShellBroker\" and \(certificate)"
    static let sourceRunner = "identifier \"org.macscope.app.SourceExecutionRunner\" and \(certificate)"
    static let launchAgent = "identifier \"org.macscope.app.ShellBrokerLaunchAgent\" and \(certificate)"
}

@objc protocol Phase2ShellBrokerXPCProtocol {
    func handshake(with reply: @escaping (Data) -> Void)
    func performCommand(_ requestData: Data, with reply: @escaping (Data) -> Void)
    func executeSource(_ requestData: Data, with reply: @escaping (Data) -> Void)
    func cancelSource(_ requestData: Data, with reply: @escaping (Data) -> Void)
    func executeScenario(_ requestData: Data, with reply: @escaping (Data) -> Void)
    func cancelScenario(_ requestData: Data, with reply: @escaping (Data) -> Void)
    func executeAssetCatalog(_ requestData: Data, with reply: @escaping (Data) -> Void)
    func cancelAssetCatalog(_ requestData: Data, with reply: @escaping (Data) -> Void)
    func invalidate()
}


/// App-owned source operations use a distinct closed capability on the existing signed connection.
enum Phase2SourceExecutionOperation: String, Codable, Equatable, Sendable {
    case inspect, compile, behavior
}
enum Phase2SourceExecutionAuthorityKind: String, Codable, Equatable, Sendable {
    case original, admittedRevision
}
struct Phase2SourceExecutionRequest: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    let requestID: UUID
    let sessionID: UUID
    let operation: Phase2SourceExecutionOperation
    let sourceAuthority: Phase2SourceExecutionAuthorityKind
    let stageRootPath: String
    let revisionSHA256: String?
    let sourceSHA256: String
    let harnessSHA256: String
    let compilerPath: String
    let sdkRootPath: String
    let toolchainRootPath: String
    let runnerSHA256: String
    let compilerSHA256: String
    let sdkSettingsSHA256: String

    var sourceProfile: ReconstructionSourceProfile? {
        ReconstructionSourceProfile.executionProfile(schemaVersion: schemaVersion)
    }

    var isValid: Bool {
        func digest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        func path(_ value: String) -> Bool {
            value.hasPrefix("/") && value.utf8.count <= 4096 && !value.utf8.contains(0)
        }
        return sourceProfile == .scalarU32V1 && path(stageRootPath) && path(compilerPath)
            && path(sdkRootPath) && path(toolchainRootPath)
            && MacScopeWorkRoot.contains(stageRootPath)
            && [sourceSHA256, harnessSHA256, runnerSHA256, compilerSHA256, sdkSettingsSHA256].allSatisfy(digest)
            && ((sourceAuthority == .original && revisionSHA256 == nil)
                || (sourceAuthority == .admittedRevision && revisionSHA256.map(digest) == true))
    }
}
enum Phase2SourceExecutionFailure: String, Codable, Equatable, Sendable {
    case cancelled, deadline, diagnosticsLimit, residentMemoryLimit
    case observationUnavailable, handshakeFailed, cleanupFailed, launchFailed, authorityRejected
}
struct Phase2SourceExecutionTerminal: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case exited, signaled, canceled, interrupted, brokerCrashed, outcomeUnknown
    }
    let kind: Kind
    let status: Int32?
    var isValid: Bool { (kind == .exited || kind == .signaled) == (status != nil) }
}
struct Phase2SourceExecutionCleanup: Codable, Equatable, Sendable {
    let sessionID: UUID
    let requestID: UUID
    let processIdentifier: Int32
    let observedProcessAbsent: Bool
    let outcome: Phase2SourceExecutionTerminal
}
struct Phase2SourceExecutionResponse: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable { case completed, rejected, invalid }
    let requestID: UUID?
    let sessionID: UUID?
    let operation: Phase2SourceExecutionOperation?
    let status: Status
    let failure: Phase2SourceExecutionFailure?
    let terminal: Phase2SourceExecutionTerminal?
    let diagnostics: Data
    let peakGroupResidentBytes: UInt64
    let sampledProcessIDs: [Int32]
    let elapsedSeconds: Double
    let cleanup: Phase2SourceExecutionCleanup?

    static func rejected(_ request: Phase2SourceExecutionRequest?, failure: Phase2SourceExecutionFailure = .authorityRejected) -> Self {
        .init(requestID: request?.requestID, sessionID: request?.sessionID, operation: request?.operation,
              status: request == nil ? .invalid : .rejected, failure: failure, terminal: nil,
              diagnostics: Data(), peakGroupResidentBytes: 0, sampledProcessIDs: [], elapsedSeconds: 0, cleanup: nil)
    }
    var isValid: Bool {
        guard diagnostics.count <= 16_384, sampledProcessIDs.count <= 1024,
              Set(sampledProcessIDs).count == sampledProcessIDs.count,
              sampledProcessIDs.allSatisfy({ $0 > 1 }), elapsedSeconds.isFinite,
              elapsedSeconds >= 0, elapsedSeconds <= 60,
              terminal?.isValid != false else { return false }
        if status == .completed {
            guard let requestID, let sessionID, operation != nil, let cleanup,
                  cleanup.requestID == requestID, cleanup.sessionID == sessionID,
                  cleanup.processIdentifier > 1, cleanup.outcome.isValid else { return false }
            if failure == nil {
                guard cleanup.observedProcessAbsent, let terminal,
                      terminal.kind != .outcomeUnknown else { return false }
            }
        } else if cleanup != nil || terminal != nil || failure == nil { return false }
        return true
    }
}
enum Phase2SourceExecutionWireCodec {
    static let protocolIdentity = "macscope.source_execution.xpc.v1"
    static let maximumBytes = 64 * 1024
    enum Failure: Error { case invalidEnvelope }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(value)
        guard bytes.count <= maximumBytes else { throw Failure.invalidEnvelope }
        return bytes
    }
    static func encodeRequest(_ value: Phase2SourceExecutionRequest) throws -> Data {
        guard value.isValid else { throw Failure.invalidEnvelope }; return try encode(value)
    }
    static func decodeRequest(_ bytes: Data) throws -> Phase2SourceExecutionRequest {
        guard bytes.count <= maximumBytes else { throw Failure.invalidEnvelope }
        let value = try JSONDecoder().decode(Phase2SourceExecutionRequest.self, from: bytes)
        guard try encodeRequest(value) == bytes else { throw Failure.invalidEnvelope }; return value
    }
    static func encodeResponse(_ value: Phase2SourceExecutionResponse) throws -> Data {
        guard value.isValid else { throw Failure.invalidEnvelope }; return try encode(value)
    }
    static func decodeResponse(_ bytes: Data) throws -> Phase2SourceExecutionResponse {
        guard bytes.count <= maximumBytes else { throw Failure.invalidEnvelope }
        let value = try JSONDecoder().decode(Phase2SourceExecutionResponse.self, from: bytes)
        guard try encodeResponse(value) == bytes else { throw Failure.invalidEnvelope }; return value
    }
}
