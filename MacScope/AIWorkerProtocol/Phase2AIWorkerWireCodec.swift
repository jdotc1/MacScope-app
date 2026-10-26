import CryptoKit
import Darwin
import Foundation

struct Phase2AIWorkerWireCodec: Sendable {
    static let protocolVersion = Phase2AIWorkerProductionProtocol.inferenceVersion
    static let maximumRawCanonicalContextBytes = 1_048_576
    static let maximumEncodedCanonicalContextBytes =
        4 * ((maximumRawCanonicalContextBytes + 2) / 3)
    static let maximumEncodedGoalBytes =
        Phase2AIWorkerWireLimits.maximum.maximumGoalBytes * 6
    // Frozen allowance for the request DTO, three evidence IDs, and three tool handles.
    static let maximumRequestFixedOverheadBytes = 16_384
    static let maximumRequestEnvelopeBytes =
        maximumEncodedCanonicalContextBytes
        + maximumEncodedGoalBytes
        + maximumRequestFixedOverheadBytes
    static let defaultMaximumEnvelopeBytes = maximumRequestEnvelopeBytes
    static let maximumEventEnvelopeBytes = 65_536
    static let maximumControlEnvelopeBytes = 4_096

    let maximumEnvelopeBytes: Int

    init(maximumEnvelopeBytes: Int = Self.defaultMaximumEnvelopeBytes) {
        self.maximumEnvelopeBytes = maximumEnvelopeBytes
    }

    func encodeHandshake(_ value: Phase2AIWorkerHandshake) throws -> Data {
        let data = try encode(
            value,
            ceiling: min(maximumEnvelopeBytes, Self.maximumControlEnvelopeBytes)
        )
        _ = try decodeHandshake(data)
        return data
    }

    func decodeHandshake(_ data: Data) throws -> Phase2AIWorkerHandshake {
        try requireClosedShape(
            data,
            .handshake,
            ceiling: min(maximumEnvelopeBytes, Self.maximumControlEnvelopeBytes)
        )
        let value: Phase2AIWorkerHandshake = try decode(
            data,
            ceiling: min(maximumEnvelopeBytes, Self.maximumControlEnvelopeBytes)
        )
        let handshakeIsBound = [
            Phase2AIWorkerProductionProtocol.standard,
            Phase2AIWorkerProductionProtocol.assistantR2,
            Phase2AIWorkerProductionProtocol.assistantR3,
            Phase2AIWorkerProductionProtocol.assistantR4,
            Phase2AIWorkerProductionProtocol.reconstructionR1,
            Phase2AIWorkerProductionProtocol.reconstructionR2,
            Phase2AIWorkerProductionProtocol.reconstructionSourceV10,
        ].contains {
            value.wireProtocol == $0.wireIdentity
                && value.inferenceProtocol == $0.inferenceIdentity
                && value.manifestIdentity == $0.manifestIdentity
        }
        guard handshakeIsBound, value.status == .ready
        else { throw Phase2AIWorkerWireError.invalidEnvelope }
        return value
    }

    func encodeRequest(_ value: Phase2AIWorkerWireRequest) throws -> Data {
        let data = try encode(value, ceiling: maximumEnvelopeBytes)
        _ = try decodeRequest(data)
        return data
    }

    func decodeRequest(_ data: Data) throws -> Phase2AIWorkerWireRequest {
        try requireClosedShape(data, .request, ceiling: maximumEnvelopeBytes)
        let value: Phase2AIWorkerWireRequest = try decode(data, ceiling: maximumEnvelopeBytes)
        let bundle = try requireCurrent(
            wireIdentity: value.wireProtocol,
            inferenceVersion: value.protocolVersion
        )
        let r1Operations = Set([
            "workspace.summary", "selection.explain", "function.review",
        ])
        // Assistant protocols carry every operation the assistant registry projects, including
        // the decompiler reads Review Function offers; a missing entry rejects the whole request.
        let r2Operations = r1Operations.union([
            "decompiler.native.result", "decompiler.macscope.result", "decompiler.compare",
            "debugger.summary", "debugger.frames", "debugger.registers",
            "debugger.variables", "debugger.memory",
            "rea.results.list", "rea.results.get",
        ])
        let knownOperations = bundle.inferenceVersion
            >= Phase2AIWorkerProductionProtocol.assistantR2.inferenceVersion
            ? r2Operations : r1Operations
        let phaseIsValid: Bool
        switch value.phase {
        case .toolSelection:
            phaseIsValid = !value.toolHandles.isEmpty
                && value.toolHandles.count <= value.limits.maximumToolHandles
                && value.shellContinuationCoordinate == nil
        case .finalization:
            phaseIsValid = value.toolHandles.isEmpty
                && value.shellContinuationCoordinate == nil
        case .shellContinuation:
            phaseIsValid = bundle == Phase2AIWorkerProductionProtocol.assistantR4
                && value.toolHandles.isEmpty
                && value.shellContinuationCoordinate.map {
                    Self.isValidShellContinuationCoordinate($0, request: value)
                } == true
        }
        let conversationIsValid: Bool
        if bundle.inferenceVersion >= Phase2AIWorkerProductionProtocol.assistantR3.inferenceVersion {
            conversationIsValid = value.conversationContext.map { context in
                guard Self.isValidConversationContext(context),
                      context.turns.allSatisfy({ $0.conversationID == value.sessionID })
                else { return false }
                switch value.phase {
                case .toolSelection:
                    return context.turns.isEmpty && context.omittedTurnCount == 0
                case .finalization:
                    return true
                case .shellContinuation:
                    return bundle == Phase2AIWorkerProductionProtocol.assistantR4
                }
            } == true
        } else {
            conversationIsValid = value.conversationContext == nil
        }
        guard phaseIsValid,
              conversationIsValid,
              value.limits.isValid,
              !value.userGoal.isEmpty,
              value.userGoal.utf8.count <= value.limits.maximumGoalBytes,
              value.canonicalContext.count <= Self.maximumRawCanonicalContextBytes,
              value.contextDigest.utf8.count == 64,
              value.contextDigest.utf8.allSatisfy({
                  (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
              }),
              value.evidenceIDs.count <= value.limits.maximumEvidenceReferences,
              Set(value.evidenceIDs).count == value.evidenceIDs.count,
              value.toolHandles.count <= value.limits.maximumToolHandles,
              Set(value.toolHandles.map(\.handleID)).count == value.toolHandles.count,
              Set(value.toolHandles.filter { $0.operationID != "rea.results.get" }.map(\.operationID)).count
                == value.toolHandles.filter { $0.operationID != "rea.results.get" }.count,
              value.toolHandles.allSatisfy({ knownOperations.contains($0.operationID) })
        else { throw Phase2AIWorkerWireError.invalidEnvelope }
        return value
    }

    func encodeEvent(_ value: Phase2AIWorkerWireEvent) throws -> Data {
        let data = try encode(
            value,
            ceiling: min(maximumEnvelopeBytes, Self.maximumEventEnvelopeBytes)
        )
        _ = try decodeEvent(data)
        return data
    }

    func decodeEvent(_ data: Data) throws -> Phase2AIWorkerWireEvent {
        try requireClosedShape(
            data,
            .event,
            ceiling: min(maximumEnvelopeBytes, Self.maximumEventEnvelopeBytes)
        )
        let value: Phase2AIWorkerWireEvent = try decode(
            data,
            ceiling: min(maximumEnvelopeBytes, Self.maximumEventEnvelopeBytes)
        )
        _ = try requireCurrent(
            wireIdentity: value.wireProtocol,
            inferenceVersion: value.protocolVersion
        )
        let estimatedBytes: Int
        switch value.body {
        case .contentDelta(let text):
            estimatedBytes = 176 + text.utf8.count
        case .toolProposal(let callID, _, let functionName, let operationID):
            estimatedBytes = 176 + callID.utf8.count + 16
                + functionName.utf8.count + operationID.utf8.count
        case .shellProposal(let proposal):
            estimatedBytes = 192
                + proposal.executablePath.utf8.count
                + proposal.arguments.reduce(0) { $0 + $1.utf8.count }
                + proposal.environment.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
                + (proposal.workingDirectoryPath?.utf8.count ?? 0)
                + proposal.executionSurface.utf8.count
                + proposal.requestedEffects.reduce(0) { $0 + $1.utf8.count }
        case .debuggerActionProposal(let proposal):
            estimatedBytes = 224
                + proposal.action.utf8.count
                + proposal.requestedAuthority.utf8.count
        case .finalCandidate(_, let text, let evidenceIDs):
            estimatedBytes = 176 + text.utf8.count + evidenceIDs.count * 16
        case .usage:
            estimatedBytes = 224
        case .providerConnection:
            estimatedBytes = 320
        case .providerDispatch:
            estimatedBytes = 176
        case .awaitingTools:
            estimatedBytes = 176
        case .completed:
            estimatedBytes = 176
        }
        let phaseBodyIsValid: Bool
        switch (value.phase, value.body) {
        case (.toolSelection, .toolProposal(
            let callID, _, let functionName, let operationID
        )):
            phaseBodyIsValid = Self.isValidCallID(callID)
                && Self.functionNameByOperation[operationID] == functionName
        case (.toolSelection, .awaitingTools):
            phaseBodyIsValid = true
        case (.finalization, .contentDelta(let text)):
            phaseBodyIsValid = !text.isEmpty && text.utf8.count <= 16_384
        case (.finalization, .shellProposal(let proposal)):
            phaseBodyIsValid = value.protocolVersion
                >= Phase2AIWorkerProductionProtocol.assistantR2.inferenceVersion
                && Self.isValidShellProposal(proposal)
        case (.finalization, .debuggerActionProposal(let proposal)):
            phaseBodyIsValid = value.protocolVersion
                >= Phase2AIWorkerProductionProtocol.assistantR2.inferenceVersion
                && Self.isValidDebuggerActionProposal(proposal)
        case (.finalization, .finalCandidate(let kind, let text, let evidenceIDs)):
            let evidenceShapeIsValid = switch kind {
            case .answer: !evidenceIDs.isEmpty
            case .insufficientEvidence: evidenceIDs.isEmpty
            }
            let kindMaximumTextBytes = switch kind {
            case .answer: 60_000
            case .insufficientEvidence: 4_096
            }
            phaseBodyIsValid = !text.isEmpty
                && text.utf8.count <= kindMaximumTextBytes
                && evidenceShapeIsValid
                && evidenceIDs.count <= Phase2AIWorkerWireLimits.maximum.maximumEvidenceReferences
                && Set(evidenceIDs).count == evidenceIDs.count
        case (_, .usage(let usage)):
            let (sum, overflow) = usage.promptTokens.addingReportingOverflow(
                usage.completionTokens
            )
            phaseBodyIsValid = value.protocolVersion
                    >= Phase2AIWorkerProductionProtocol.stagedV3InferenceVersion
                && usage.promptTokens >= 0
                && usage.completionTokens >= 0
                && usage.totalTokens >= 0
                && !overflow
                && sum == usage.totalTokens
        case (_, .providerConnection(let receipt)):
            phaseBodyIsValid = value.protocolVersion
                    >= Phase2AIWorkerProductionProtocol.stagedV3InferenceVersion
                && Self.isIPAddress(receipt.localAddress)
                && Self.isIPAddress(receipt.remoteAddress)
                && (1...Int(UInt16.max)).contains(receipt.localPort)
                && (1...Int(UInt16.max)).contains(receipt.remotePort)
        case (_, .providerDispatch):
            phaseBodyIsValid = value.protocolVersion
                >= Phase2AIWorkerProductionProtocol.stagedV3InferenceVersion
        case (.finalization, .completed):
            phaseBodyIsValid = true
        case (.shellContinuation, .contentDelta(let text)):
            phaseBodyIsValid = !text.isEmpty && text.utf8.count <= 16_384
        case (.shellContinuation, .finalCandidate(let kind, let text, let evidenceIDs)):
            let maximumTextBytes = kind == .answer ? 60_000 : 4_096
            phaseBodyIsValid = !text.isEmpty
                && text.utf8.count <= maximumTextBytes
                && (kind == .answer ? !evidenceIDs.isEmpty : evidenceIDs.isEmpty)
                && evidenceIDs.count
                    <= Phase2AIWorkerWireLimits.maximum.maximumEvidenceReferences
                && Set(evidenceIDs).count == evidenceIDs.count
        case (.shellContinuation, .completed):
            phaseBodyIsValid = true
        default:
            phaseBodyIsValid = false
        }
        guard phaseBodyIsValid,
              value.sequence > 0,
              estimatedBytes <= Self.maximumEventEnvelopeBytes
        else {
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
        return value
    }

    func encodeTerminal(_ value: Phase2AIWorkerTerminal) throws -> Data {
        let data = try encode(
            value,
            ceiling: min(maximumEnvelopeBytes, Self.maximumControlEnvelopeBytes)
        )
        _ = try decodeTerminal(data)
        return data
    }

    func decodeTerminal(_ data: Data) throws -> Phase2AIWorkerTerminal {
        try requireClosedShape(
            data,
            .terminal,
            ceiling: min(maximumEnvelopeBytes, Self.maximumControlEnvelopeBytes)
        )
        let value: Phase2AIWorkerTerminal = try decode(
            data,
            ceiling: min(maximumEnvelopeBytes, Self.maximumControlEnvelopeBytes)
        )
        _ = try requireCurrent(
            wireIdentity: value.wireProtocol,
            inferenceVersion: value.protocolVersion
        )
        let phaseStatusIsValid: Bool
        switch (value.phase, value.status) {
        case (.toolSelection?, .awaitingTools), (.finalization?, .completed),
             (.shellContinuation?, .completed),
             (_, .cancelled), (_, .failed):
            phaseStatusIsValid = true
        default:
            phaseStatusIsValid = false
        }
        let reasonIsValid = switch value.status {
        case .failed: value.reason != nil
        case .completed, .awaitingTools, .cancelled: value.reason == nil
        }
        guard phaseStatusIsValid, reasonIsValid else {
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
        return value
    }

    private func encode<Value: Encodable>(_ value: Value, ceiling: Int) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            throw Phase2AIWorkerWireError.malformedEnvelope
        }
        try requireBound(data, ceiling: ceiling)
        return data
    }

    private func decode<Value: Decodable>(_ data: Data, ceiling: Int) throws -> Value {
        try requireBound(data, ceiling: ceiling)
        guard Phase2StrictJSONValidator.validate(
            data,
            limits: .productionEnvelope
        ) else {
            throw Phase2AIWorkerWireError.malformedEnvelope
        }
        guard let value = try? JSONDecoder().decode(Value.self, from: data) else {
            throw Phase2AIWorkerWireError.malformedEnvelope
        }
        return value
    }

    private func requireBound(_ data: Data, ceiling: Int) throws {
        guard ceiling > 0, data.count <= ceiling else {
            throw Phase2AIWorkerWireError.envelopeTooLarge
        }
    }

    private func requireCurrent(_ version: Int) throws {
        guard version == Self.protocolVersion else {
            throw Phase2AIWorkerWireError.unsupportedProtocolVersion(version)
        }
    }

    private func requireCurrent(
        wireIdentity: String,
        inferenceVersion: Int
    ) throws -> Phase2AIWorkerProductionProtocolBundle {
        for bundle in [
            Phase2AIWorkerProductionProtocol.standard,
            Phase2AIWorkerProductionProtocol.assistantR2,
            Phase2AIWorkerProductionProtocol.assistantR3,
            Phase2AIWorkerProductionProtocol.assistantR4,
            Phase2AIWorkerProductionProtocol.reconstructionR1,
            Phase2AIWorkerProductionProtocol.reconstructionR2,
            Phase2AIWorkerProductionProtocol.reconstructionSourceV10,
        ] where bundle.inferenceVersion == inferenceVersion {
            guard bundle.wireIdentity == wireIdentity else {
                throw Phase2AIWorkerWireError.unsupportedWireProtocol(wireIdentity)
            }
            return bundle
        }
        throw Phase2AIWorkerWireError.unsupportedProtocolVersion(inferenceVersion)
    }

    private func requireWireCurrent(_ identity: String) throws {
        guard identity == Phase2AIWorkerProductionProtocol.wireIdentity else {
            throw Phase2AIWorkerWireError.unsupportedWireProtocol(identity)
        }
    }

    private static func isValidCallID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= 256
            && !bytes.contains(where: { $0 < 0x20 || $0 == 0x7f })
    }

    static func isValidConversationContext(
        _ context: Phase2AIWorkerWireConversationContext
    ) -> Bool {
        guard context.turns.count <= 8,
              context.omittedTurnCount >= 0 else { return false }
        var priorSequence: UInt64?
        var conversationID: UUID?
        var inferenceTurnIDs: Set<UUID> = []
        var bytes = 0
        for turn in context.turns {
            guard !turn.isLegacy,
                  turn.turnSequence > 0,
                  priorSequence.map({ turn.turnSequence > $0 }) ?? true,
                  !turn.user.isEmpty,
                  !turn.assistant.isEmpty,
                  !turn.user.utf8.contains(0),
                  !turn.assistant.utf8.contains(0),
                  inferenceTurnIDs.insert(turn.inferenceTurnID).inserted,
                  conversationID.map({ $0 == turn.conversationID }) ?? true else { return false }
            priorSequence = turn.turnSequence
            conversationID = turn.conversationID
            let (withUser, overflow1) = bytes.addingReportingOverflow(turn.user.utf8.count)
            let (withAssistant, overflow2) = withUser.addingReportingOverflow(turn.assistant.utf8.count)
            guard !overflow1, !overflow2,
                  withAssistant <= 65_536 else {
                return false
            }
            bytes = withAssistant
        }
        return true
    }

    private static func isValidShellContinuationCoordinate(
        _ coordinate: Phase2AIWorkerWireShellContinuationCoordinate,
        request: Phase2AIWorkerWireRequest
    ) -> Bool {
        let digests = [
            coordinate.shellProposalDigest,
            coordinate.shellExecutionResultDigest,
            coordinate.runtimeAuthorityRecordDigest,
        ]
        let reservedIDs = [
            coordinate.workspaceID, coordinate.conversationID, coordinate.inferenceTurnID,
            coordinate.originatingFinalizationRequestID, coordinate.shellProposalID,
            coordinate.shellExecutionID, coordinate.runtimeAuthorityRecordID,
            coordinate.continuationRequestID,
        ]
        return reservedIDs.allSatisfy({ $0 != Self.zeroUUID })
            && Set(reservedIDs).count == reservedIDs.count
            && coordinate.workspaceID == request.workspaceID
            && coordinate.conversationID == request.sessionID
            && coordinate.inferenceTurnID == request.turnID
            && coordinate.continuationRequestID == request.requestID
            && coordinate.turnSequence > 0
            && coordinate.providerRevision > 0
            && coordinate.continuationOrdinal == 1
            && coordinate.productionManifestIdentity
                == Phase2AIWorkerProductionProtocol.assistantR4.manifestIdentity
            && coordinate.integrityDigest == Self.shellContinuationIntegrityDigest(coordinate)
            && (digests + [coordinate.workspaceDocumentIdentityDigest, coordinate.integrityDigest])
                .allSatisfy { digest in
                digest.utf8.count == 64 && digest.utf8.allSatisfy {
                    (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
                }
            }
    }

    private static let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private static func shellContinuationIntegrityDigest(
        _ coordinate: Phase2AIWorkerWireShellContinuationCoordinate
    ) -> String {
        var data = Data()
        [
            "phase2-assistant-shell-continuation-coordinate-v1",
            coordinate.workspaceID.uuidString.lowercased(),
            coordinate.workspaceDocumentIdentityDigest,
            coordinate.conversationID.uuidString.lowercased(),
            coordinate.inferenceTurnID.uuidString.lowercased(),
            String(coordinate.turnSequence),
            coordinate.originatingFinalizationRequestID.uuidString.lowercased(),
            coordinate.shellProposalID.uuidString.lowercased(),
            coordinate.shellExecutionID.uuidString.lowercased(),
            coordinate.runtimeAuthorityRecordID.uuidString.lowercased(),
            coordinate.shellProposalDigest,
            coordinate.shellExecutionResultDigest,
            coordinate.runtimeAuthorityRecordDigest,
            coordinate.productionManifestIdentity,
            String(coordinate.providerRevision),
            String(coordinate.continuationOrdinal),
            coordinate.continuationRequestID.uuidString.lowercased(),
        ].forEach { field in
            let bytes = Data(field.utf8)
            var count = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 { return true }
        var ipv6 = in6_addr()
        return inet_pton(AF_INET6, value, &ipv6) == 1
    }

    private static func isValidShellProposal(
        _ proposal: Phase2AIWorkerWireShellProposal
    ) -> Bool {
        let nilUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        guard proposal.proposalID != nilUUID,
              isValidAbsolutePath(proposal.executablePath),
              proposal.arguments.count <= 64,
              proposal.arguments.allSatisfy({ !$0.containsNUL }),
              proposal.environment.count <= 64,
              proposal.environment.allSatisfy({ key, value in
                  !key.isEmpty
                      && !key.contains("=")
                      && !key.containsNUL
                      && !value.containsNUL
              }),
              proposal.workingDirectoryPath.map(isValidAbsolutePath) ?? true,
              (1...120_000).contains(proposal.timeoutMilliseconds),
              (1...1_048_576).contains(proposal.maximumOutputBytes),
              ["restrictedOneShotJob", "shellBrokerPTY"].contains(proposal.executionSurface),
              Set(proposal.requestedEffects) == Set(["A5"])
        else { return false }
        return true
    }

    private static func isValidDebuggerActionProposal(
        _ proposal: Phase2AIWorkerWireDebuggerActionProposal
    ) -> Bool {
        let nilUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        guard proposal.proposalID != nilUUID,
              proposal.sessionID != nilUUID,
              proposal.lifecycleRevision > 0,
              proposal.eventSequence != nil,
              proposal.requestedAuthority == "controlledRuntimeActions"
        else { return false }
        switch proposal.action {
        case "continueExecution", "stepOver", "stepInto", "stepOut", "refreshSnapshot":
            return proposal.stopRevision != nil
        case "pause":
            return true
        default:
            return false
        }
    }

    private static func isValidAbsolutePath(_ value: String) -> Bool {
        !value.isEmpty && value.hasPrefix("/") && !value.containsNUL
    }

    private static let functionNameByOperation = [
        "workspace.summary": "macscope_workspace_summary_v1",
        "selection.explain": "macscope_selection_explain_v1",
        "function.review": "macscope_function_review_v1",
        "decompiler.native.result": "macscope_native_decompilation_v1",
        "decompiler.macscope.result": "macscope_decompilation_v1",
        "decompiler.compare": "macscope_decompiler_compare_v1",
        "debugger.summary": "macscope_debugger_summary_v1",
        "debugger.frames": "macscope_debugger_frames_v1",
        "debugger.registers": "macscope_debugger_registers_v1",
        "debugger.variables": "macscope_debugger_variables_v1",
        "debugger.memory": "macscope_debugger_memory_v1",
        "rea.results.list": "macscope_rea_results_list_v1",
        "rea.results.get": "macscope_rea_results_get_v1",
    ]

    private enum ClosedShape {
        case handshake
        case request
        case event
        case terminal
    }

    private func requireClosedShape(
        _ data: Data,
        _ shape: ClosedShape,
        ceiling: Int
    ) throws {
        try requireBound(data, ceiling: ceiling)
        guard Phase2StrictJSONValidator.validate(
                  data,
                  limits: .productionEnvelope
              ),
              let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any]
        else {
            throw Phase2AIWorkerWireError.malformedEnvelope
        }

        let valid: Bool
        switch shape {
        case .handshake:
            valid = Self.hasExactKeys(
                object,
                ["wireProtocol", "inferenceProtocol", "manifestIdentity", "status"]
            )
        case .request:
            let baseKeys: Set<String> = [
                "wireProtocol", "protocolVersion", "phase", "sessionID", "turnID",
                "requestID", "documentID", "workspaceID", "lifecycleRevision", "userGoal",
                "canonicalContext", "contextDigest", "evidenceIDs", "toolHandles", "limits",
            ]
            let version = (object["protocolVersion"] as? NSNumber)?.intValue
            let hasConversation = [
                Phase2AIWorkerProductionProtocol.assistantR3.inferenceVersion,
                Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion,
            ].contains(version)
            let isContinuation = version
                == Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion
                && (object["phase"] as? String) == Phase2AIWorkerWirePhase.shellContinuation.rawValue
            valid = Self.hasExactKeys(
                object,
                baseKeys
                    .union(hasConversation ? ["conversationContext"] : [])
                    .union(isContinuation ? ["shellContinuationCoordinate"] : [])
            ) && Self.requestMembersAreClosed(
                object,
                requiresConversationContext: hasConversation,
                requiresShellContinuationCoordinate: isContinuation
            )
        case .event:
            valid = Self.hasExactKeys(object, [
                "wireProtocol", "protocolVersion", "phase", "sessionID", "turnID",
                "requestID", "documentID", "workspaceID", "lifecycleRevision", "sequence",
                "body",
            ]) && Self.eventBodyIsClosed(object["body"])
        case .terminal:
            valid = Self.hasClosedKeys(
                object,
                required: ["wireProtocol", "protocolVersion", "requestID", "status"],
                optional: ["phase", "reason"]
            )
        }
        guard valid else { throw Phase2AIWorkerWireError.invalidEnvelope }
    }

    private static func requestMembersAreClosed(
        _ object: [String: Any],
        requiresConversationContext: Bool,
        requiresShellContinuationCoordinate: Bool
    ) -> Bool {
        guard let handleValues = object["toolHandles"] as? [Any],
              handleValues.allSatisfy({ value in
                  guard let handle = value as? [String: Any] else { return false }
                  return hasExactKeys(handle, ["handleID", "operationID"])
              }),
              let limits = object["limits"] as? [String: Any],
              hasExactKeys(limits, [
                  "maximumGoalBytes", "maximumEventBytes", "maximumCumulativeEventBytes",
                  "maximumEvents", "maximumToolHandles", "maximumToolProposals",
                  "maximumFinalTextBytes", "maximumEvidenceReferences",
              ])
        else { return false }
        if requiresConversationContext {
            guard let context = object["conversationContext"] as? [String: Any],
                  hasExactKeys(context, ["turns", "omittedTurnCount"]),
                  let turns = context["turns"] as? [Any],
                  turns.allSatisfy({ value in
                      guard let turn = value as? [String: Any] else { return false }
                      return hasExactKeys(turn, [
                          "conversationID", "inferenceTurnID", "turnSequence", "user",
                          "assistant", "isLegacy",
                      ])
                  }) else { return false }
        }
        if requiresShellContinuationCoordinate {
            guard let coordinate = object["shellContinuationCoordinate"] as? [String: Any],
                  hasExactKeys(coordinate, [
                    "workspaceID", "workspaceDocumentIdentityDigest", "conversationID", "inferenceTurnID",
                    "turnSequence", "originatingFinalizationRequestID", "shellProposalID",
                    "shellExecutionID", "runtimeAuthorityRecordID", "shellProposalDigest",
                    "shellExecutionResultDigest", "runtimeAuthorityRecordDigest",
                    "productionManifestIdentity", "providerRevision", "continuationOrdinal",
                    "continuationRequestID", "integrityDigest",
                  ]) else { return false }
        }
        return true
    }

    private static func eventBodyIsClosed(_ value: Any?) -> Bool {
        guard let body = value as? [String: Any], body.count == 1,
              let (kind, payloadValue) = body.first,
              let payload = payloadValue as? [String: Any]
        else { return false }
        switch kind {
        case "contentDelta":
            return hasExactKeys(payload, ["_0"])
        case "toolProposal":
            return hasExactKeys(
                payload,
                ["callID", "handleID", "functionName", "operationID"]
            )
        case "shellProposal":
            guard hasExactKeys(payload, ["_0"]),
                  let proposal = payload["_0"] as? [String: Any]
            else { return false }
            return hasClosedKeys(
                proposal,
                required: [
                    "proposalID", "executablePath", "arguments", "environment",
                    "timeoutMilliseconds", "maximumOutputBytes", "executionSurface",
                    "requestedEffects",
                ],
                optional: ["workingDirectoryPath"]
            )
        case "debuggerActionProposal":
            guard hasExactKeys(payload, ["_0"]),
                  let proposal = payload["_0"] as? [String: Any]
            else { return false }
            return hasClosedKeys(
                proposal,
                required: [
                    "proposalID", "action", "sessionID", "lifecycleRevision", "eventSequence",
                    "requestedAuthority",
                ],
                optional: ["stopRevision"]
            )
        case "finalCandidate":
            return hasExactKeys(payload, ["kind", "text", "evidenceIDs"])
        case "usage":
            guard hasExactKeys(payload, ["_0"]),
                  let usage = payload["_0"] as? [String: Any]
            else { return false }
            return hasExactKeys(
                usage,
                ["promptTokens", "completionTokens", "totalTokens"]
            )
        case "providerConnection":
            guard hasExactKeys(payload, ["_0"]),
                  let receipt = payload["_0"] as? [String: Any]
            else { return false }
            return hasExactKeys(
                receipt,
                ["localAddress", "localPort", "remoteAddress", "remotePort"]
            )
        case "providerDispatch", "awaitingTools", "completed":
            return payload.isEmpty
        default:
            return false
        }
    }

    private static func hasExactKeys(
        _ object: [String: Any],
        _ keys: Set<String>
    ) -> Bool {
        Set(object.keys) == keys
    }

    private static func hasClosedKeys(
        _ object: [String: Any],
        required: Set<String>,
        optional: Set<String>
    ) -> Bool {
        let actual = Set(object.keys)
        return required.isSubset(of: actual) && actual.isSubset(of: required.union(optional))
    }
}

/// A small structural pass closes JSONDecoder's duplicate-key ambiguity. It validates one
/// complete RFC-8259 value and tracks keys independently at every object nesting level.
struct Phase2AIWorkerWireJSONLimits: Equatable, Sendable {
    let maximumDepth: Int
    let maximumTokens: Int
    let maximumMembersAndElements: Int

    static let productionEnvelope = Self(
        maximumDepth: 16,
        maximumTokens: 4_096,
        maximumMembersAndElements: 1_024
    )
}

struct Phase2StrictJSONValidator {
    private let bytes: [UInt8]
    private let limits: Phase2AIWorkerWireJSONLimits
    private var index = 0
    private var tokenCount = 0
    private var memberCount = 0

    static func validate(
        _ data: Data,
        limits: Phase2AIWorkerWireJSONLimits = .productionEnvelope
    ) -> Bool {
        guard limits.maximumDepth > 0,
              limits.maximumTokens > 0,
              limits.maximumMembersAndElements > 0
        else { return false }
        var parser = Self(bytes: Array(data), limits: limits)
        guard parser.parseValue(depth: 0) else { return false }
        parser.skipWhitespace()
        return parser.index == parser.bytes.count
    }

    private mutating func parseValue(depth: Int) -> Bool {
        skipWhitespace()
        guard index < bytes.count else { return false }
        switch bytes[index] {
        case 0x7b: return parseObject(depth: depth + 1)
        case 0x5b: return parseArray(depth: depth + 1)
        case 0x22: return parseString() != nil
        case 0x74: return consumeToken("true")
        case 0x66: return consumeToken("false")
        case 0x6e: return consumeToken("null")
        default: return parseNumber()
        }
    }

    private mutating func parseObject(depth: Int) -> Bool {
        guard depth <= limits.maximumDepth, recordToken() else { return false }
        index += 1
        skipWhitespace()
        if consumeTokenByte(0x7d) { return true }
        var keys: Set<String> = []
        while true {
            skipWhitespace()
            guard let key = parseString(), keys.insert(key).inserted else { return false }
            skipWhitespace()
            guard consumeTokenByte(0x3a), recordMember(), parseValue(depth: depth) else {
                return false
            }
            skipWhitespace()
            if consumeTokenByte(0x7d) { return true }
            guard consumeTokenByte(0x2c) else { return false }
        }
    }

    private mutating func parseArray(depth: Int) -> Bool {
        guard depth <= limits.maximumDepth, recordToken() else { return false }
        index += 1
        skipWhitespace()
        if consumeTokenByte(0x5d) { return true }
        while true {
            guard recordMember(), parseValue(depth: depth) else { return false }
            skipWhitespace()
            if consumeTokenByte(0x5d) { return true }
            guard consumeTokenByte(0x2c) else { return false }
        }
    }

    private mutating func parseString() -> String? {
        let quotedStart = index
        guard recordToken(), consumeByte(0x22) else { return nil }
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte < 0x20 { return nil }
            index += 1
            if escaped {
                if byte == 0x75 {
                    guard index + 4 <= bytes.count,
                          bytes[index..<(index + 4)].allSatisfy(Self.isHex)
                    else { return nil }
                    index += 4
                } else if ![0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74].contains(byte) {
                    return nil
                }
                escaped = false
            } else if byte == 0x5c {
                escaped = true
            } else if byte == 0x22 {
                let data = Data(bytes[quotedStart..<index])
                return try? JSONDecoder().decode(String.self, from: data)
            }
        }
        return nil
    }

    private mutating func parseNumber() -> Bool {
        guard recordToken() else { return false }
        let start = index
        if consumeByte(0x2d), index == bytes.count { return false }
        if consumeByte(0x30) {
            if index < bytes.count, Self.isDigit(bytes[index]) { return false }
        } else {
            guard index < bytes.count, (0x31...0x39).contains(bytes[index]) else { return false }
            while index < bytes.count, Self.isDigit(bytes[index]) { index += 1 }
        }
        if consumeByte(0x2e) {
            guard index < bytes.count, Self.isDigit(bytes[index]) else { return false }
            while index < bytes.count, Self.isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count && (bytes[index] == 0x65 || bytes[index] == 0x45) {
            index += 1
            if index < bytes.count && (bytes[index] == 0x2b || bytes[index] == 0x2d) {
                index += 1
            }
            guard index < bytes.count, Self.isDigit(bytes[index]) else { return false }
            while index < bytes.count, Self.isDigit(bytes[index]) { index += 1 }
        }
        return index > start
    }

    private mutating func consumeToken(_ literal: StaticString) -> Bool {
        guard recordToken() else { return false }
        let candidate = Array(String(describing: literal).utf8)
        guard index + candidate.count <= bytes.count,
              Array(bytes[index..<(index + candidate.count)]) == candidate
        else { return false }
        index += candidate.count
        return true
    }

    private mutating func consumeByte(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func consumeTokenByte(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte, recordToken() else { return false }
        index += 1
        return true
    }

    private mutating func recordToken() -> Bool {
        tokenCount += 1
        return tokenCount <= limits.maximumTokens
    }

    private mutating func recordMember() -> Bool {
        memberCount += 1
        return memberCount <= limits.maximumMembersAndElements
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) { index += 1 }
    }

    private static func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
    private static func isHex(_ byte: UInt8) -> Bool {
        isDigit(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
}

private extension String {
    var containsNUL: Bool {
        utf8.contains(0)
    }
}
