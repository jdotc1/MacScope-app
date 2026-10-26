import CryptoKit
import Foundation

struct Phase2ReconstructionAIWorkerWireCodec: Sendable {
    static let wireIdentity = "phase2.ai-worker-wire.v8"
    static let protocolVersion = 8
    static let r2WireIdentity = "phase2.ai-worker-wire.v9"
    static let r2ProtocolVersion = 9
    static let sourceWireIdentity = "phase2.ai-worker-wire.v10"
    static let maximumEnvelopeBytes = 1_500_000
    private static let maximumContextBytes = 1_048_576
    private static let maximumEvidenceIDs = 4_096
    private static let maximumHandles = 15
    private static let maximumGaps = 64

    func encodeSourceRequest(_ request: ReconstructionSourceRevisionRequest, requestID: UUID) throws -> Data {
        try request.validate()
        return try encode(R2RequestEnvelope(wireProtocol: Self.sourceWireIdentity, phase: .sourceRevision, requestID: requestID, request: request))
    }

    func encodeRoundRequestR2(_ request: ReconstructionInferenceRoundRequestR2, requestID: UUID) throws -> Data {
        guard request.protocolVersion == Self.r2ProtocolVersion, request.objective.jobID == request.request.jobID
        else { throw ReconstructionAIWorkerWireError.invalidAuthority }
        try validate(request.request, allowsTransientAnalysis: true)
        return try encode(R2RequestEnvelope(wireProtocol: Self.r2WireIdentity, phase: .round, requestID: requestID, request: request))
    }

    func encodeFinalRequestR2(_ request: ReconstructionFinalSynthesisRequestR2, requestID: UUID) throws -> Data {
        guard request.protocolVersion == Self.r2ProtocolVersion, request.objective.jobID == request.request.jobID
        else { throw ReconstructionAIWorkerWireError.invalidAuthority }
        try validate(request.request)
        return try encode(R2RequestEnvelope(wireProtocol: Self.r2WireIdentity, phase: .finalSynthesis, requestID: requestID, request: request))
    }

    func encodeRoundRequest(
        _ request: ReconstructionInferenceRoundRequest,
        requestID: UUID
    ) throws -> Data {
        try validate(request)
        return try encode(RequestEnvelope(
            wireProtocol: Self.wireIdentity,
            phase: .round,
            requestID: requestID,
            request: request,
            finalRequest: nil
        ))
    }

    func encodeFinalRequest(
        _ request: ReconstructionFinalSynthesisRequest,
        requestID: UUID
    ) throws -> Data {
        try validate(request)
        return try encode(RequestEnvelope(
            wireProtocol: Self.wireIdentity,
            phase: .finalSynthesis,
            requestID: requestID,
            request: nil,
            finalRequest: request
        ))
    }

    func decodeRequest(_ data: Data) throws -> ReconstructionAIWorkerDecodedRequest {
        try validateEnvelope(data)
        guard try objectKeys(data) == ["phase", "request", "requestID", "wireProtocol"]
        else { throw ReconstructionAIWorkerWireError.invalidEnvelope }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let wireProtocol = object["wireProtocol"] as? String,
              let phaseValue = object["phase"] as? String,
              let phase = ReconstructionAIWorkerPhase(rawValue: phaseValue),
              let requestIDValue = object["requestID"] as? String,
              let requestID = UUID(uuidString: requestIDValue),
              let requestObject = object["request"],
              JSONSerialization.isValidJSONObject(requestObject)
        else { throw ReconstructionAIWorkerWireError.invalidEnvelope }
        guard wireProtocol == Self.wireIdentity || wireProtocol == Self.r2WireIdentity || wireProtocol == Self.sourceWireIdentity else {
            throw ReconstructionAIWorkerWireError.unsupportedProtocol
        }
        let requestData = try JSONSerialization.data(
            withJSONObject: requestObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        if wireProtocol == Self.sourceWireIdentity {
            guard phase == .sourceRevision else { throw ReconstructionAIWorkerWireError.invalidEnvelope }
            _ = try Phase2StrictJSONParser().parse(data, limits: .init(maximumBytes: Self.maximumEnvelopeBytes,
                maximumDepth: 32, maximumTokens: 100_000, maximumMembersAndElements: 50_000))
            let request = try decode(ReconstructionSourceRevisionRequest.self, from: requestData)
            guard try encodeSourceRequest(request, requestID: requestID) == data else { throw ReconstructionAIWorkerWireError.invalidEnvelope }
            return .sourceRevision(requestID: requestID, request: request)
        }
        if wireProtocol == Self.r2WireIdentity {
            do {
                _ = try Phase2StrictJSONParser().parse(data, limits: .init(
                    maximumBytes: Self.maximumEnvelopeBytes, maximumDepth: 32,
                    maximumTokens: 100_000, maximumMembersAndElements: 50_000
                ))
            } catch { throw ReconstructionAIWorkerWireError.invalidEnvelope }
            guard let wrapper = requestObject as? [String: Any],
                  Set(wrapper.keys) == ["protocolVersion", "objective", "request"],
                  let objective = wrapper["objective"] as? [String: Any],
                  (Set(objective.keys) == ["jobID", "text", "sha256"]
                    || Set(objective.keys) == ["jobID", "text", "sha256", "sourceProfileID"]),
                  let semantic = wrapper["request"] else {
                throw ReconstructionAIWorkerWireError.invalidEnvelope
            }
            try validateRequestShape(semantic, phase: phase, allowsTransientAnalysis: true)
            switch phase {
            case .sourceRevision: throw ReconstructionAIWorkerWireError.unsupportedProtocol
            case .round:
                let request = try decode(ReconstructionInferenceRoundRequestR2.self, from: requestData)
                _ = try encodeRoundRequestR2(request, requestID: requestID)
                return .roundR2(requestID: requestID, request: request)
            case .finalSynthesis:
                let request = try decode(ReconstructionFinalSynthesisRequestR2.self, from: requestData)
                _ = try encodeFinalRequestR2(request, requestID: requestID)
                return .finalSynthesisR2(requestID: requestID, request: request)
            }
        }
        try validateRequestShape(requestObject, phase: phase)
        switch phase {
        case .sourceRevision: throw ReconstructionAIWorkerWireError.unsupportedProtocol
        case .round:
            let request = try decode(ReconstructionInferenceRoundRequest.self, from: requestData)
            try validate(request)
            return .round(requestID: requestID, request: request)
        case .finalSynthesis:
            let request = try decode(ReconstructionFinalSynthesisRequest.self, from: requestData)
            try validate(request)
            return .finalSynthesis(requestID: requestID, request: request)
        }
    }

    func encodeEvent(
        _ event: ReconstructionAIWorkerEvent,
        authority: ReconstructionAIWorkerAuthority
    ) throws -> Data {
        try validate(event, authority: authority)
        let body: EventBodyEnvelope
        switch event.body {
        case .sourceCandidate(let candidate):
            body = .init(kind: "sourceCandidate", sourceCandidate: candidate)
        case .roundCandidate(let candidate):
            body = .init(kind: "roundCandidate", roundCandidate: candidate)
        case .finalCandidate(let candidate):
            body = .init(kind: "finalCandidate", finalCandidate: candidate)
        case .usage(let usage):
            body = .init(kind: "usage", usage: usage)
        case .completed:
            body = .init(kind: "completed")
        }
        return try encode(EventEnvelope(
            wireProtocol: eventWireIdentity(authority),
            requestID: event.requestID,
            sequence: event.sequence,
            body: body
        ))
    }

    func decodeEvent(
        _ data: Data,
        authority: ReconstructionAIWorkerAuthority
    ) throws -> ReconstructionAIWorkerEvent {
        try validateEnvelope(data)
        guard try objectKeys(data) == ["body", "requestID", "sequence", "wireProtocol"]
        else { throw ReconstructionAIWorkerWireError.invalidEnvelope }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = object["body"] as? [String: Any]
        else { throw ReconstructionAIWorkerWireError.invalidEnvelope }
        try validateEventBodyShape(body)
        let envelope = try decode(EventEnvelope.self, from: data)
        guard envelope.wireProtocol == eventWireIdentity(authority), envelope.sequence > 0 else {
            throw ReconstructionAIWorkerWireError.invalidEnvelope
        }
        let eventBody: ReconstructionAIWorkerEventBody
        switch envelope.body.kind {
        case "sourceCandidate":
            guard let candidate = envelope.body.sourceCandidate else { throw ReconstructionAIWorkerWireError.invalidEnvelope }
            eventBody = .sourceCandidate(candidate)
        case "roundCandidate":
            guard let value = envelope.body.roundCandidate,
                  envelope.body.finalCandidate == nil, envelope.body.usage == nil
            else { throw ReconstructionAIWorkerWireError.invalidEnvelope }
            eventBody = .roundCandidate(value)
        case "finalCandidate":
            guard let value = envelope.body.finalCandidate,
                  envelope.body.roundCandidate == nil, envelope.body.usage == nil
            else { throw ReconstructionAIWorkerWireError.invalidEnvelope }
            eventBody = .finalCandidate(value)
        case "usage":
            guard let value = envelope.body.usage,
                  envelope.body.roundCandidate == nil, envelope.body.finalCandidate == nil
            else { throw ReconstructionAIWorkerWireError.invalidEnvelope }
            eventBody = .usage(value)
        case "completed":
            guard envelope.body.roundCandidate == nil,
                  envelope.body.finalCandidate == nil,
                  envelope.body.usage == nil
            else { throw ReconstructionAIWorkerWireError.invalidEnvelope }
            eventBody = .completed
        default:
            throw ReconstructionAIWorkerWireError.invalidEnvelope
        }
        let event = ReconstructionAIWorkerEvent(
            requestID: envelope.requestID,
            sequence: envelope.sequence,
            body: eventBody
        )
        try validate(event, authority: authority)
        if case .sourceRevision = authority {
            _ = try Phase2StrictJSONParser().parse(data, limits: .init(maximumBytes: Self.maximumEnvelopeBytes,
                maximumDepth: 32, maximumTokens: 100_000, maximumMembersAndElements: 50_000))
            guard try encodeEvent(event, authority: authority) == data else { throw ReconstructionAIWorkerWireError.invalidEnvelope }
        }
        return event
    }

    private func validate(
        _ request: ReconstructionInferenceRoundRequest,
        allowsTransientAnalysis: Bool = false
    ) throws {
        // Transient native semantics are an R2-only presentation; R1 stays byte-identical.
        if let transient = request.transientAnalysis {
            guard allowsTransientAnalysis else { throw ReconstructionAIWorkerWireError.invalidAuthority }
            do { try transient.validate(for: request) } catch {
                throw ReconstructionAIWorkerWireError.invalidAuthority
            }
        }
        let artifacts = Phase2ReconstructionProtocolArtifacts.make()
        guard request.protocolVersion == Self.protocolVersion,
              validDigest(request.corpusManifestSHA256),
              validDigest(request.evidenceFrontierSHA256),
              request.registryManifestSHA256 == artifacts.toolRegistry.identity.sha256,
              validContext(request.context),
              (1...Self.maximumHandles).contains(request.handles.count),
              Set(request.handles.map(\.handleID)).count == request.handles.count,
              Set(request.handles.map(\.operationID)).count == request.handles.count
        else { throw ReconstructionAIWorkerWireError.invalidAuthority }
        // Source operations publish durable authority through dedicated protocols, never read tools.
        let known = Set(ReconstructionOperationID.allCases.filter { !$0.isDurableSourceOperation })
        guard request.handles.allSatisfy({ known.contains($0.operationID) }) else {
            throw ReconstructionAIWorkerWireError.invalidAuthority
        }
    }

    private func validate(_ request: ReconstructionFinalSynthesisRequest) throws {
        guard validDigest(request.corpusManifestSHA256),
              validDigest(request.evidenceFrontierSHA256),
              validContext(request.context),
              request.acceptedEvidenceIDs.count <= Self.maximumEvidenceIDs,
              Set(request.acceptedEvidenceIDs).count == request.acceptedEvidenceIDs.count,
              Set(request.acceptedEvidenceIDs).isSubset(of: Set(request.context.evidenceIDs))
        else { throw ReconstructionAIWorkerWireError.invalidAuthority }
    }

    private func validate(
        _ event: ReconstructionAIWorkerEvent,
        authority: ReconstructionAIWorkerAuthority
    ) throws {
        guard event.sequence > 0 else { throw ReconstructionAIWorkerWireError.invalidEnvelope }
        switch authority {
        case .roundR2(let value):
            _ = try encodeRoundRequestR2(value, requestID: event.requestID)
            return try validate(event, authority: .round(value.request))
        case .finalSynthesisR2(let value):
            _ = try encodeFinalRequestR2(value, requestID: event.requestID)
            return try validate(event, authority: .finalSynthesis(value.request))
        default: break
        }
        switch (authority, event.body) {
        case (.sourceRevision(let request), .sourceCandidate(let candidate)):
            try candidate.validate(for: request)
        case (.round(let request), .roundCandidate(let candidate)):
            let selectedHandleIDs = Set(candidate.selectedHandleIDs)
            let sortedResolvedGaps = candidate.resolvedGaps.sorted {
                if $0.gapID != $1.gapID {
                    return $0.gapID.uuidString.lowercased() < $1.gapID.uuidString.lowercased()
                }
                if $0.handleID != $1.handleID {
                    return $0.handleID.uuidString.lowercased()
                        < $1.handleID.uuidString.lowercased()
                }
                return $0.evidenceID.uuidString.lowercased()
                    < $1.evidenceID.uuidString.lowercased()
            }
            guard candidate.jobID == request.jobID,
                  candidate.checkpointRevision == request.checkpointRevision,
                  candidate.roundID == request.roundID,
                  candidate.selectedHandleIDs.count <= request.handles.count,
                  Set(candidate.selectedHandleIDs).count == candidate.selectedHandleIDs.count,
                  Set(candidate.selectedHandleIDs).isSubset(of: Set(request.handles.map(\.handleID))),
                  candidate.resolvedGaps.count <= Self.maximumGaps,
                  candidate.resolvedGaps == sortedResolvedGaps,
                  Set(candidate.resolvedGaps).count == candidate.resolvedGaps.count,
                  Set(candidate.resolvedGaps.map(\.gapID)).count == candidate.resolvedGaps.count,
                  candidate.resolvedGaps.allSatisfy({
                      selectedHandleIDs.contains($0.handleID)
                          && request.context.allowedGapIDs.contains($0.gapID)
                          && request.context.evidenceIDs.contains($0.evidenceID)
                  }),
                  candidate.unresolvedGaps.count <= Self.maximumGaps,
                  Set(candidate.unresolvedGaps).count == candidate.unresolvedGaps.count,
                  candidate.unresolvedGaps.allSatisfy({
                      !$0.subject.isEmpty && $0.subject.utf8.count <= 16_384
                          && !$0.category.isEmpty && $0.category.utf8.count <= 16_384
                          && !$0.reason.isEmpty && $0.reason.utf8.count <= 1_024
                          && request.context.allowedGapSubjects.contains($0.subject)
                          && request.context.allowedGapCategories.contains($0.category)
                  })
            else { throw ReconstructionAIWorkerWireError.invalidAuthority }
        case (.finalSynthesis(let request), .finalCandidate(let candidate)):
            let textBytes = candidate.text.utf8.count
            let kindShapeIsValid: Bool
            switch candidate.kind {
            case .synthesis:
                kindShapeIsValid = (1...60_000).contains(textBytes)
                    && !candidate.evidenceIDs.isEmpty
            case .insufficientEvidence:
                kindShapeIsValid = (1...4_096).contains(textBytes)
                    && candidate.evidenceIDs.isEmpty
            }
            guard kindShapeIsValid,
                  candidate.evidenceIDs.count <= Self.maximumEvidenceIDs,
                  Set(candidate.evidenceIDs).count == candidate.evidenceIDs.count,
                  Set(candidate.evidenceIDs).isSubset(of: Set(request.acceptedEvidenceIDs))
            else { throw ReconstructionAIWorkerWireError.invalidAuthority }
        case (_, .usage(let usage)):
            let (expectedTotalTokens, tokenCountOverflow) = usage.promptTokens
                .addingReportingOverflow(usage.completionTokens)
            guard usage.promptTokens >= 0, usage.completionTokens >= 0,
                  !tokenCountOverflow,
                  usage.totalTokens == expectedTotalTokens
            else { throw ReconstructionAIWorkerWireError.invalidEnvelope }
        case (_, .completed):
            break
        default:
            throw ReconstructionAIWorkerWireError.invalidAuthority
        }
    }

    private func validContext(_ context: ReconstructionRetrievedContext) -> Bool {
        context.canonicalBytes.count <= Self.maximumContextBytes
            && !context.canonicalBytes.isEmpty
            && context.canonicalSHA256 == sha256(context.canonicalBytes)
            && context.evidenceIDs.count <= Self.maximumEvidenceIDs
            && Set(context.evidenceIDs).count == context.evidenceIDs.count
            && context.allowedGapIDs.count <= Self.maximumGaps
            && Set(context.allowedGapIDs).count == context.allowedGapIDs.count
            && context.allowedGapSubjects.count <= Self.maximumGaps
            && context.allowedGapCategories.count <= Self.maximumGaps
            && Set(context.allowedGapSubjects).count == context.allowedGapSubjects.count
            && Set(context.allowedGapCategories).count == context.allowedGapCategories.count
            && context.allowedGapSubjects.allSatisfy(validGapAuthorityValue)
            && context.allowedGapCategories.allSatisfy(validGapAuthorityValue)
    }

    private func eventWireIdentity(_ authority: ReconstructionAIWorkerAuthority) -> String {
        switch authority {
        case .sourceRevision: Self.sourceWireIdentity
        case .roundR2, .finalSynthesisR2: Self.r2WireIdentity
        case .round, .finalSynthesis: Self.wireIdentity
        }
    }

    private func validGapAuthorityValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384
    }

    private func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private func validateEnvelope(_ data: Data) throws {
        guard data.count <= Self.maximumEnvelopeBytes,
              Phase2StrictJSONValidator.validate(data)
        else { throw ReconstructionAIWorkerWireError.boundsExceeded }
    }

    private func objectKeys(_ data: Data) throws -> Set<String> {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReconstructionAIWorkerWireError.invalidEnvelope
        }
        return Set(object.keys)
    }

    private func validateRequestShape(
        _ value: Any,
        phase: ReconstructionAIWorkerPhase,
        allowsTransientAnalysis: Bool = false
    ) throws {
        guard let request = value as? [String: Any] else {
            throw ReconstructionAIWorkerWireError.invalidEnvelope
        }
        let required: Set<String>
        switch phase {
        case .sourceRevision: throw ReconstructionAIWorkerWireError.unsupportedProtocol
        case .round:
            required = [
                "protocolVersion", "jobID", "checkpointRevision", "roundID",
                "corpusManifestSHA256", "evidenceFrontierSHA256",
                "registryManifestSHA256", "context", "handles",
            ]
        case .finalSynthesis:
            required = [
                "jobID", "checkpointRevision", "corpusManifestSHA256",
                "evidenceFrontierSHA256", "acceptedEvidenceIDs", "context",
            ]
        }
        let optional: Set<String> = phase == .round && allowsTransientAnalysis
            ? ["transientAnalysis"] : []
        guard required.isSubset(of: Set(request.keys)),
              Set(request.keys).isSubset(of: required.union(optional)),
              let context = request["context"] as? [String: Any],
              Set(context.keys) == [
                  "canonicalBytes", "canonicalSHA256", "evidenceIDs",
                  "allowedGapSubjects", "allowedGapCategories", "allowedGapIDs",
              ]
        else { throw ReconstructionAIWorkerWireError.invalidEnvelope }
        if phase == .round {
            guard let handles = request["handles"] as? [[String: Any]],
                  handles.allSatisfy({ Set($0.keys) == ["handleID", "operationID"] })
            else { throw ReconstructionAIWorkerWireError.invalidEnvelope }
        }
    }

    private func validateEventBodyShape(_ body: [String: Any]) throws {
        guard let kind = body["kind"] as? String else {
            throw ReconstructionAIWorkerWireError.invalidEnvelope
        }
        switch kind {
        case "sourceCandidate":
            guard Set(body.keys) == ["kind", "sourceCandidate"], let candidate = body["sourceCandidate"] as? [String: Any],
                  Set(candidate.keys).subtracting(["parentRevisionSHA256"]) == ["profileID", "sourceText", "evidenceIDs"] else { throw ReconstructionAIWorkerWireError.invalidEnvelope }
        case "roundCandidate":
            guard Set(body.keys) == ["kind", "roundCandidate"],
                  let candidate = body["roundCandidate"] as? [String: Any],
                  Set(candidate.keys) == [
                      "jobID", "checkpointRevision", "roundID", "selectedHandleIDs",
                      "disposition", "unresolvedGaps", "resolvedGaps",
                  ],
                  let gaps = candidate["unresolvedGaps"] as? [[String: Any]],
                  gaps.allSatisfy({ Set($0.keys) == ["subject", "category", "reason"] }),
                  let resolvedGaps = candidate["resolvedGaps"] as? [[String: Any]],
                  resolvedGaps.allSatisfy({
                      Set($0.keys) == ["gapID", "handleID", "evidenceID"]
                  })
            else { throw ReconstructionAIWorkerWireError.invalidEnvelope }
        case "finalCandidate":
            guard Set(body.keys) == ["kind", "finalCandidate"],
                  let candidate = body["finalCandidate"] as? [String: Any],
                  Set(candidate.keys) == ["kind", "text", "evidenceIDs"]
            else { throw ReconstructionAIWorkerWireError.invalidEnvelope }
        case "usage":
            guard Set(body.keys) == ["kind", "usage"],
                  let usage = body["usage"] as? [String: Any],
                  Set(usage.keys) == ["promptTokens", "completionTokens", "totalTokens"]
            else { throw ReconstructionAIWorkerWireError.invalidEnvelope }
        case "completed":
            guard Set(body.keys) == ["kind"] else {
                throw ReconstructionAIWorkerWireError.invalidEnvelope
            }
        default:
            throw ReconstructionAIWorkerWireError.invalidEnvelope
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try validateEnvelope(data)
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw ReconstructionAIWorkerWireError.invalidEnvelope }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct R2RequestEnvelope<Request: Encodable>: Encodable {
    let wireProtocol: String
    let phase: ReconstructionAIWorkerPhase
    let requestID: UUID
    let request: Request
}

private struct RequestEnvelope<Request: Encodable>: Encodable {
    let wireProtocol: String
    let phase: ReconstructionAIWorkerPhase
    let requestID: UUID
    private let request: Request

    init(
        wireProtocol: String,
        phase: ReconstructionAIWorkerPhase,
        requestID: UUID,
        request: ReconstructionInferenceRoundRequest?,
        finalRequest: ReconstructionFinalSynthesisRequest?
    ) where Request == EitherRequest {
        self.wireProtocol = wireProtocol
        self.phase = phase
        self.requestID = requestID
        self.request = request.map(EitherRequest.round)
            ?? finalRequest.map(EitherRequest.finalSynthesis)!
    }
}

private enum EitherRequest: Encodable {
    case round(ReconstructionInferenceRoundRequest)
    case finalSynthesis(ReconstructionFinalSynthesisRequest)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .round(let value): try value.encode(to: encoder)
        case .finalSynthesis(let value): try value.encode(to: encoder)
        }
    }
}

private struct EventEnvelope: Codable {
    let wireProtocol: String
    let requestID: UUID
    let sequence: UInt64
    let body: EventBodyEnvelope
}

private struct EventBodyEnvelope: Codable {
    let kind: String
    let sourceCandidate: ReconstructionSourceRevisionCandidate?
    let roundCandidate: ReconstructionInferenceRoundCandidate?
    let finalCandidate: ReconstructionFinalSynthesisCandidate?
    let usage: Phase2AIWorkerWireUsage?

    init(
        kind: String,
        sourceCandidate: ReconstructionSourceRevisionCandidate? = nil,
        roundCandidate: ReconstructionInferenceRoundCandidate? = nil,
        finalCandidate: ReconstructionFinalSynthesisCandidate? = nil,
        usage: Phase2AIWorkerWireUsage? = nil
    ) {
        self.kind = kind
        self.sourceCandidate = sourceCandidate
        self.roundCandidate = roundCandidate
        self.finalCandidate = finalCandidate
        self.usage = usage
    }
}
