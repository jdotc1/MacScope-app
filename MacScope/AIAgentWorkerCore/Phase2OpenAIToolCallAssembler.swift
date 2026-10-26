import CryptoKit
import Foundation

struct Phase2OpenAIToolCall: Equatable, Sendable {
    let opaqueCallID: String
    let functionName: String
    let handleID: UUID
}

struct Phase2OpenAIShellProposalToolCall: Equatable, Sendable {
    let proposalID: UUID
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryPath: String?
    let timeoutMilliseconds: Int
    let maximumOutputBytes: Int
    let executionSurface: String
    let requestedEffects: [String]
}

struct Phase2OpenAIDebuggerActionProposalToolCall: Equatable, Sendable {
    let proposalID: UUID
    let action: String
    let sessionID: UUID
    let lifecycleRevision: UInt64
    let stopRevision: UInt64?
    let eventSequence: UInt64?
    let requestedAuthority: String
}

struct Phase2OpenAIToolCallFragment: Equatable, Sendable {
    let index: Int
    let id: String?
    let type: String?
    let name: String?
    let arguments: String?

    init(
        index: Int,
        id: String? = nil,
        type: String? = nil,
        name: String? = nil,
        arguments: String? = nil
    ) {
        self.index = index
        self.id = id
        self.type = type
        self.name = name
        self.arguments = arguments
    }
}

private extension Phase2ProductionJSONValue {
    func member(_ key: String) -> Phase2ProductionJSONValue? {
        objectValue?[key]
    }

    var integerValue: Int? {
        guard case .number(let lexeme) = self,
              !lexeme.contains("."),
              !lexeme.contains("e"),
              !lexeme.contains("E") else { return nil }
        return Int(lexeme)
    }
}

private extension Dictionary where Key == String, Value == Phase2ProductionJSONValue {
    func member(_ key: String) -> Phase2ProductionJSONValue? {
        self[key]
    }

    func keysAreSubset(of allowed: Set<String>) -> Bool {
        keys.allSatisfy(allowed.contains)
    }
}

struct Phase2OpenAIToolCallLimits: Equatable, Sendable {
    let maximumCalls: Int
    let maximumCallIDBytes: Int
    let maximumArgumentBytesPerCall: Int
    let maximumCumulativeArgumentBytes: Int

    init(
        maximumCalls: Int = 3,
        maximumCallIDBytes: Int = 256,
        maximumArgumentBytesPerCall: Int = 4_096,
        maximumCumulativeArgumentBytes: Int = 8_192
    ) {
        precondition((1...8).contains(maximumCalls))
        precondition(maximumCallIDBytes > 0 && maximumCallIDBytes <= 256)
        precondition(maximumArgumentBytesPerCall > 0 && maximumArgumentBytesPerCall <= 4_096)
        precondition(maximumCumulativeArgumentBytes > 0 && maximumCumulativeArgumentBytes <= 8_192)
        self.maximumCalls = maximumCalls
        self.maximumCallIDBytes = maximumCallIDBytes
        self.maximumArgumentBytesPerCall = maximumArgumentBytesPerCall
        self.maximumCumulativeArgumentBytes = maximumCumulativeArgumentBytes
    }
}

enum Phase2OpenAIToolCallError: Error, Equatable, Sendable {
    case invalidIndex
    case noncontiguousIndices
    case invalidAtomicMetadata
    case atomicMetadataMismatch
    case argumentLimitExceeded
    case incompleteCall
    case invalidArguments
    case unknownFunctionHandlePair
    case duplicateCallID
    case duplicateHandle
    case alreadyFinished
    case alreadyFailed
}

struct Phase2OpenAIToolCallAssembler: Sendable {
    private struct PartialCall: Sendable {
        var id: String?
        var type: String?
        var name: String?
        var argumentBytes: [UInt8] = []
    }

    private let offeredFunctionHandles: [String: Set<UUID>]
    private let limits: Phase2OpenAIToolCallLimits
    private var calls: [Int: PartialCall] = [:]
    private var cumulativeArgumentBytes = 0
    private var isFinished = false
    private var isFailed = false

    init(
        offeredFunctionHandles: [String: UUID],
        limits: Phase2OpenAIToolCallLimits = .init()
    ) {
        precondition(!offeredFunctionHandles.isEmpty)
        precondition(offeredFunctionHandles.count <= 8)
        self.offeredFunctionHandles = offeredFunctionHandles.mapValues { [$0] }
        self.limits = limits
    }

    init(allowedFunctionHandles: [String: Set<UUID>], limits: Phase2OpenAIToolCallLimits = .init()) {
        precondition(!allowedFunctionHandles.isEmpty)
        self.offeredFunctionHandles = allowedFunctionHandles
        self.limits = limits
    }

    init(
        projectedTools: [Phase2ProductionProjectedTool],
        limits: Phase2OpenAIToolCallLimits = .init()
    ) {
        precondition(!projectedTools.isEmpty)
        self.offeredFunctionHandles = Dictionary(uniqueKeysWithValues:
            projectedTools.map { ($0.functionName, Set($0.acceptedHandleIDs)) })
        self.limits = limits
    }

    mutating func append(_ fragment: Phase2OpenAIToolCallFragment) throws {
        guard !isFinished else { throw Phase2OpenAIToolCallError.alreadyFinished }
        guard !isFailed else { throw Phase2OpenAIToolCallError.alreadyFailed }
        do {
            guard fragment.index >= 0, fragment.index < limits.maximumCalls else {
                throw Phase2OpenAIToolCallError.invalidIndex
            }
            var call = calls[fragment.index] ?? PartialCall()
            try freeze(fragment.id, into: &call.id, kind: .id)
            try freeze(fragment.type, into: &call.type, kind: .type)
            try freeze(fragment.name, into: &call.name, kind: .name)
            if let arguments = fragment.arguments {
                let bytes = Array(arguments.utf8)
                guard bytes.count <= limits.maximumArgumentBytesPerCall - call.argumentBytes.count,
                      bytes.count <= limits.maximumCumulativeArgumentBytes - cumulativeArgumentBytes else {
                    throw Phase2OpenAIToolCallError.argumentLimitExceeded
                }
                call.argumentBytes.append(contentsOf: bytes)
                cumulativeArgumentBytes += bytes.count
            }
            calls[fragment.index] = call
        } catch {
            isFailed = true
            throw error
        }
    }

    mutating func finish() throws -> [Phase2OpenAIToolCall] {
        guard !isFinished else { throw Phase2OpenAIToolCallError.alreadyFinished }
        guard !isFailed else { throw Phase2OpenAIToolCallError.alreadyFailed }
        do {
            guard !calls.isEmpty else { throw Phase2OpenAIToolCallError.incompleteCall }
            let indices = calls.keys.sorted()
            guard indices == Array(0..<indices.count) else {
                throw Phase2OpenAIToolCallError.noncontiguousIndices
            }

            var result: [Phase2OpenAIToolCall] = []
            var callIDs = Set<[UInt8]>()
            var handles = Set<UUID>()
            for index in indices {
                guard let call = calls[index],
                      let id = call.id,
                      call.type == "function",
                      let name = call.name else {
                    throw Phase2OpenAIToolCallError.incompleteCall
                }
                let handle = try decodeHandle(from: call.argumentBytes)
                guard offeredFunctionHandles[name]?.contains(handle) == true else {
                    throw Phase2OpenAIToolCallError.unknownFunctionHandlePair
                }
                guard callIDs.insert(Array(id.utf8)).inserted else {
                    throw Phase2OpenAIToolCallError.duplicateCallID
                }
                guard handles.insert(handle).inserted else {
                    throw Phase2OpenAIToolCallError.duplicateHandle
                }
                result.append(.init(opaqueCallID: id, functionName: name, handleID: handle))
            }
            isFinished = true
            return result
        } catch {
            isFailed = true
            throw error
        }
    }

    private enum AtomicKind { case id, type, name }

    private func freeze(_ value: String?, into frozen: inout String?, kind: AtomicKind) throws {
        guard let value else { return }
        let byteCount = value.utf8.count
        guard byteCount > 0 else { throw Phase2OpenAIToolCallError.invalidAtomicMetadata }
        switch kind {
        case .id:
            guard byteCount <= limits.maximumCallIDBytes,
                  !value.unicodeScalars.contains(where: { $0.value <= 0x1F || $0.value == 0x7F }) else {
                throw Phase2OpenAIToolCallError.invalidAtomicMetadata
            }
        case .type:
            guard value == "function" else {
                if frozen == nil { throw Phase2OpenAIToolCallError.invalidAtomicMetadata }
                throw Phase2OpenAIToolCallError.atomicMetadataMismatch
            }
        case .name:
            guard offeredFunctionHandles[value] != nil else {
                throw Phase2OpenAIToolCallError.invalidAtomicMetadata
            }
        }
        if let frozen {
            let matches: Bool
            switch kind {
            case .id: matches = frozen.utf8.elementsEqual(value.utf8)
            case .type, .name: matches = frozen == value
            }
            guard matches else { throw Phase2OpenAIToolCallError.atomicMetadataMismatch }
        }
        frozen = value
    }

    private func decodeHandle(from bytes: [UInt8]) throws -> UUID {
        do {
            let value = try Phase2StrictJSONParser().parse(Data(bytes), limits: .toolArguments)
            guard case .object(let members) = value,
                  members.count == 1,
                  case .string(let text) = members["handle_id"],
                  text.utf8.count == 36,
                  let uuid = UUID(uuidString: text),
                  uuid.uuidString == text else {
                throw Phase2OpenAIToolCallError.invalidArguments
            }
            return uuid
        } catch is Phase2OpenAIToolCallError {
            throw Phase2OpenAIToolCallError.invalidArguments
        } catch {
            throw Phase2OpenAIToolCallError.invalidArguments
        }
    }
}

struct Phase2OpenAIShellProposalToolCallAssembler: Sendable {
    private struct PartialCall: Sendable {
        var id: String?
        var type: String?
        var name: String?
        var argumentBytes: [UInt8] = []
    }

    private let limits: Phase2OpenAIToolCallLimits
    private var call: PartialCall?
    private var isFinished = false
    private var isFailed = false

    init(limits: Phase2OpenAIToolCallLimits = .init(maximumCalls: 1)) {
        self.limits = limits
    }

    var hasFragments: Bool { call != nil }

    mutating func append(_ fragment: Phase2OpenAIToolCallFragment) throws {
        guard !isFinished else { throw Phase2OpenAIToolCallError.alreadyFinished }
        guard !isFailed else { throw Phase2OpenAIToolCallError.alreadyFailed }
        do {
            guard fragment.index == 0 else { throw Phase2OpenAIToolCallError.invalidIndex }
            var current = call ?? PartialCall()
            try freeze(fragment.id, into: &current.id, kind: .id)
            try freeze(fragment.type, into: &current.type, kind: .type)
            try freeze(fragment.name, into: &current.name, kind: .name)
            if let arguments = fragment.arguments {
                let bytes = Array(arguments.utf8)
                guard bytes.count <= limits.maximumArgumentBytesPerCall - current.argumentBytes.count else {
                    throw Phase2OpenAIToolCallError.argumentLimitExceeded
                }
                current.argumentBytes.append(contentsOf: bytes)
            }
            call = current
        } catch {
            isFailed = true
            throw error
        }
    }

    mutating func finishIfPresent() throws -> [Phase2OpenAIShellProposalToolCall] {
        guard let call else { return [] }
        guard !isFinished else { throw Phase2OpenAIToolCallError.alreadyFinished }
        guard !isFailed else { throw Phase2OpenAIToolCallError.alreadyFailed }
        do {
            guard let id = call.id,
                  call.type == "function",
                  call.name == Phase2OpenAIShellProposalFunctionTool.functionName else {
                throw Phase2OpenAIToolCallError.incompleteCall
            }
            let proposal = try decodeProposal(from: call.argumentBytes, callID: id)
            isFinished = true
            return [proposal]
        } catch {
            isFailed = true
            throw error
        }
    }

    private enum AtomicKind { case id, type, name }

    private func freeze(_ value: String?, into frozen: inout String?, kind: AtomicKind) throws {
        guard let value else { return }
        let byteCount = value.utf8.count
        guard byteCount > 0 else { throw Phase2OpenAIToolCallError.invalidAtomicMetadata }
        switch kind {
        case .id:
            guard byteCount <= limits.maximumCallIDBytes,
                  !value.unicodeScalars.contains(where: { $0.value <= 0x1F || $0.value == 0x7F }) else {
                throw Phase2OpenAIToolCallError.invalidAtomicMetadata
            }
        case .type:
            guard value == "function" else {
                if frozen == nil { throw Phase2OpenAIToolCallError.invalidAtomicMetadata }
                throw Phase2OpenAIToolCallError.atomicMetadataMismatch
            }
        case .name:
            guard value == Phase2OpenAIShellProposalFunctionTool.functionName else {
                throw Phase2OpenAIToolCallError.invalidAtomicMetadata
            }
        }
        if let frozen {
            guard frozen == value else { throw Phase2OpenAIToolCallError.atomicMetadataMismatch }
        }
        frozen = value
    }

    private func decodeProposal(
        from bytes: [UInt8],
        callID: String
    ) throws -> Phase2OpenAIShellProposalToolCall {
        do {
            let value = try Phase2StrictJSONParser().parse(
                Data(bytes),
                limits: .shellProposalToolArguments
            )
            guard case .object(let members) = value,
                  members.keysAreSubset(of: [
                      "executable_path", "arguments", "environment", "working_directory_path",
                      "timeout_milliseconds", "maximum_output_bytes", "execution_surface",
                      "requested_effects",
                  ]),
                  members.count == 8,
                  let executablePath = members.member("executable_path")?.stringValue,
                  let arguments = stringArray(members.member("arguments")),
                  let environment = environmentDictionary(members.member("environment")),
                  let workingDirectory = members.member("working_directory_path")?.stringValue,
                  let timeoutMilliseconds = members.member("timeout_milliseconds")?.integerValue,
                  let maximumOutputBytes = members.member("maximum_output_bytes")?.integerValue,
                  let executionSurface = members.member("execution_surface")?.stringValue,
                  let requestedEffects = stringArray(members.member("requested_effects")),
                  (1...4_096).contains(executablePath.utf8.count),
                  arguments.count <= 64,
                  arguments.allSatisfy({ $0.utf8.count <= 4_096 }),
                  environment.count <= 64,
                  workingDirectory.utf8.count <= 4_096,
                  (1...120_000).contains(timeoutMilliseconds),
                  (1...1_048_576).contains(maximumOutputBytes),
                  executionSurface == "restrictedOneShotJob"
                    || executionSurface == "shellBrokerPTY",
                  requestedEffects == ["A5"] else {
                throw Phase2OpenAIToolCallError.invalidArguments
            }
            return .init(
                proposalID: proposalID(from: callID),
                executablePath: executablePath,
                arguments: arguments,
                environment: environment,
                workingDirectoryPath: workingDirectory.isEmpty ? nil : workingDirectory,
                timeoutMilliseconds: timeoutMilliseconds,
                maximumOutputBytes: maximumOutputBytes,
                executionSurface: executionSurface,
                requestedEffects: requestedEffects
            )
        } catch is Phase2OpenAIToolCallError {
            throw Phase2OpenAIToolCallError.invalidArguments
        } catch {
            throw Phase2OpenAIToolCallError.invalidArguments
        }
    }

    private func stringArray(_ value: Phase2ProductionJSONValue?) -> [String]? {
        guard let values = value?.arrayValue else { return nil }
        var result: [String] = []
        result.reserveCapacity(values.count)
        for value in values {
            guard let string = value.stringValue else { return nil }
            result.append(string)
        }
        return result
    }

    private func environmentDictionary(_ value: Phase2ProductionJSONValue?) -> [String: String]? {
        guard let values = value?.arrayValue, values.count <= 64 else { return nil }
        var result: [String: String] = [:]
        for value in values {
            guard let object = value.objectValue,
                  object.keysAreSubset(of: ["key", "value"]),
                  object.count == 2,
                  let key = object.member("key")?.stringValue,
                  let environmentValue = object.member("value")?.stringValue,
                  (1...256).contains(key.utf8.count),
                  environmentValue.utf8.count <= 4_096,
                  result[key] == nil else {
                return nil
            }
            result[key] = environmentValue
        }
        return result
    }

    private func proposalID(from callID: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(callID.utf8)).prefix(16))
        var bytes = digest
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

struct Phase2OpenAIDebuggerActionProposalToolCallAssembler: Sendable {
    private static let allowedActions: Set<String> = [
        "continueExecution", "stepOver", "stepInto", "stepOut", "pause", "refreshSnapshot",
    ]

    private struct PartialCall: Sendable {
        var id: String?
        var type: String?
        var name: String?
        var argumentBytes: [UInt8] = []
    }

    private let limits: Phase2OpenAIToolCallLimits
    private var call: PartialCall?
    private var isFinished = false
    private var isFailed = false

    init(limits: Phase2OpenAIToolCallLimits = .init(maximumCalls: 1)) {
        self.limits = limits
    }

    var hasFragments: Bool { call != nil }

    mutating func append(_ fragment: Phase2OpenAIToolCallFragment) throws {
        guard !isFinished else { throw Phase2OpenAIToolCallError.alreadyFinished }
        guard !isFailed else { throw Phase2OpenAIToolCallError.alreadyFailed }
        do {
            guard fragment.index == 0 else { throw Phase2OpenAIToolCallError.invalidIndex }
            var current = call ?? PartialCall()
            try freeze(fragment.id, into: &current.id, kind: .id)
            try freeze(fragment.type, into: &current.type, kind: .type)
            try freeze(fragment.name, into: &current.name, kind: .name)
            if let arguments = fragment.arguments {
                let bytes = Array(arguments.utf8)
                guard bytes.count <= limits.maximumArgumentBytesPerCall - current.argumentBytes.count else {
                    throw Phase2OpenAIToolCallError.argumentLimitExceeded
                }
                current.argumentBytes.append(contentsOf: bytes)
            }
            call = current
        } catch {
            isFailed = true
            throw error
        }
    }

    mutating func finishIfPresent() throws -> [Phase2OpenAIDebuggerActionProposalToolCall] {
        guard let call else { return [] }
        guard !isFinished else { throw Phase2OpenAIToolCallError.alreadyFinished }
        guard !isFailed else { throw Phase2OpenAIToolCallError.alreadyFailed }
        do {
            guard let id = call.id,
                  call.type == "function",
                  call.name == Phase2OpenAIDebuggerActionProposalFunctionTool.functionName else {
                throw Phase2OpenAIToolCallError.incompleteCall
            }
            let proposal = try decodeProposal(from: call.argumentBytes, callID: id)
            isFinished = true
            return [proposal]
        } catch {
            isFailed = true
            throw error
        }
    }

    private enum AtomicKind { case id, type, name }

    private func freeze(_ value: String?, into frozen: inout String?, kind: AtomicKind) throws {
        guard let value else { return }
        let byteCount = value.utf8.count
        guard byteCount > 0 else { throw Phase2OpenAIToolCallError.invalidAtomicMetadata }
        switch kind {
        case .id:
            guard byteCount <= limits.maximumCallIDBytes,
                  !value.unicodeScalars.contains(where: { $0.value <= 0x1F || $0.value == 0x7F }) else {
                throw Phase2OpenAIToolCallError.invalidAtomicMetadata
            }
        case .type:
            guard value == "function" else {
                if frozen == nil { throw Phase2OpenAIToolCallError.invalidAtomicMetadata }
                throw Phase2OpenAIToolCallError.atomicMetadataMismatch
            }
        case .name:
            guard value == Phase2OpenAIDebuggerActionProposalFunctionTool.functionName else {
                throw Phase2OpenAIToolCallError.invalidAtomicMetadata
            }
        }
        if let frozen {
            guard frozen == value else { throw Phase2OpenAIToolCallError.atomicMetadataMismatch }
        }
        frozen = value
    }

    private func decodeProposal(
        from bytes: [UInt8],
        callID: String
    ) throws -> Phase2OpenAIDebuggerActionProposalToolCall {
        do {
            let value = try Phase2StrictJSONParser().parse(
                Data(bytes),
                limits: .debuggerProposalToolArguments
            )
            guard case .object(let members) = value,
                  members.keysAreSubset(of: [
                      "action", "session_id", "lifecycle_revision", "stop_revision",
                      "event_sequence", "requested_authority",
                  ]),
                  members.count == 6,
                  let action = members.member("action")?.stringValue,
                  let sessionIDText = members.member("session_id")?.stringValue,
                  let sessionID = UUID(uuidString: sessionIDText),
                  sessionID.uuidString == sessionIDText,
                  let lifecycleRevision = members.member("lifecycle_revision")?.integerValue,
                  let stopRevision = members.member("stop_revision")?.integerValue,
                  let eventSequence = members.member("event_sequence")?.integerValue,
                  let requestedAuthority = members.member("requested_authority")?.stringValue,
                  Self.allowedActions.contains(action),
                  (1...Int(Int32.max)).contains(lifecycleRevision),
                  (0...Int(Int32.max)).contains(stopRevision),
                  (1...Int(Int32.max)).contains(eventSequence),
                  requestedAuthority == "controlledRuntimeActions" else {
                throw Phase2OpenAIToolCallError.invalidArguments
            }
            return .init(
                proposalID: proposalID(from: callID),
                action: action,
                sessionID: sessionID,
                lifecycleRevision: UInt64(lifecycleRevision),
                stopRevision: stopRevision == 0 ? nil : UInt64(stopRevision),
                eventSequence: eventSequence == 0 ? nil : UInt64(eventSequence),
                requestedAuthority: requestedAuthority
            )
        } catch is Phase2OpenAIToolCallError {
            throw Phase2OpenAIToolCallError.invalidArguments
        } catch {
            throw Phase2OpenAIToolCallError.invalidArguments
        }
    }

    private func proposalID(from callID: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(callID.utf8)).prefix(16))
        var bytes = digest
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
