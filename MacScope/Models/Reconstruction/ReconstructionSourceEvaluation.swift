import CryptoKit
import Foundation

/// One durable evaluation of one admitted revision. The three phases are observations of one
/// executeSource task, never independently invented tool receipts. All types are worker-neutral.
struct ReconstructionSourceEvaluation: Codable, Hashable, Sendable {
    static let version = 1
    static let profileID = ReconstructionSourceProfile.scalarU32V1.rawValue
    static let maximumPayloadBytes = 131_072
    enum Status: String, Codable, Hashable, Sendable {
        case accepted, inspectionRejected, buildRejected, behaviorMismatch, behaviorRejected
        case cancelled, transportFailed, invalidAuthority, changedInputs, invalidInspection
        case invalidExecutable, invalidBehaviorOutput
    }
    enum Operation: String, Codable, Hashable, Sendable { case inspect, compile, behavior }
    struct Terminal: Codable, Hashable, Sendable {
        enum Kind: String, Codable, Hashable, Sendable { case exited, signaled, canceled, interrupted, brokerCrashed, outcomeUnknown }
        let kind: Kind
        let status: Int32?
    }
    struct Cleanup: Codable, Hashable, Sendable {
        let sessionID: UUID
        let requestID: UUID
        let processIdentifier: Int32
        let observedProcessAbsent: Bool
        let outcome: Terminal
    }
    struct Phase: Codable, Hashable, Sendable {
        enum Status: String, Codable, Hashable, Sendable { case completed, rejected, transportFailed }
        let operation: Operation
        let requestID: UUID
        let sessionID: UUID
        let requestIdentitySHA256: String
        let status: Status
        let terminal: Terminal?
        let failure: String?
        let diagnostics: Data
        let cleanup: Cleanup?
        let sampledProcessIDs: [Int32]
        let peakGroupResidentBytes: UInt64
        let elapsedMilliseconds: UInt64
    }
    struct Observation: Codable, Hashable, Sendable { let input: UInt32; let output: UInt32 }
    struct Mismatch: Codable, Hashable, Sendable { let index: Int; let input: UInt32; let expected: UInt32; let actual: UInt32 }
    struct CapturedOutcome: Codable, Hashable, Sendable {
        let status: Status
        let failureDetail: String?
        let runnerSHA256: String
        let compilerSHA256: String
        let sdkSettingsSHA256: String
        let harnessSHA256: String
        let inspectionSHA256: String?
        let astSHA256: String?
        let executableSHA256: String?
        let phases: [Phase]
        let observations: [Observation]
        let mismatches: [Mismatch]
    }
    let version: Int
    let profileID: String
    let projectID: UUID
    let jobID: UUID
    let taskID: UUID
    let checkpointRevision: UInt64
    let evaluationRequestSHA256: String
    let function: ReconstructionFunctionCoordinate
    let sourceEvidenceID: UUID
    let sourcePayloadSHA256: String
    let revisionSHA256: String
    let sourceSHA256: String
    let sourceRequestSHA256: String
    let oracleEvidenceID: UUID
    let oraclePayloadSHA256: String
    let oracleSuiteSHA256: String
    let producerSHA256: String
    let capturedOutcome: CapturedOutcome
    let evaluationSHA256: String
}

/// Pure bounded content validation. It does not authenticate the claimed execution; graph/runtime
/// owners must independently supply the actual source, oracle, receipt, task and captured outcome.
enum ReconstructionSourceEvaluationCodec {
    enum Failure: Error, Equatable { case bounds, malformed, noncanonical, invalidIdentity, invalidOutcome }
    static func encode(_ evaluation: ReconstructionSourceEvaluation) throws -> Data {
        let bytes = try ReconstructionCanonicalJSON.encode(evaluation)
        guard bytes.count <= ReconstructionSourceEvaluation.maximumPayloadBytes else { throw Failure.bounds }
        return bytes
    }
    static func canonicalIdentity(_ evaluation: ReconstructionSourceEvaluation) throws -> String {
        guard var object = try JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(evaluation)) as? [String: Any] else { throw Failure.malformed }
        object.removeValue(forKey: "evaluationSHA256")
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func decodeAndValidateCanonical(payload: Data) throws -> ReconstructionSourceEvaluation {
        guard !payload.isEmpty, payload.count <= ReconstructionSourceEvaluation.maximumPayloadBytes else { throw Failure.bounds }
        let value: ReconstructionSourceEvaluation
        do {
            let root = try JSONSerialization.jsonObject(with: payload)
            var pending: [(Any, Int)] = [(root, 0)], visited = 0
            while let (node, depth) = pending.popLast() {
                visited += 1
                guard depth <= 16, visited <= 8_192 else { throw Failure.bounds }
                if let object = node as? [String: Any] { pending.append(contentsOf: object.values.map { ($0, depth + 1) }) }
                else if let array = node as? [Any] { pending.append(contentsOf: array.map { ($0, depth + 1) }) }
                guard pending.count <= 8_192 else { throw Failure.bounds }
            }
            value = try JSONDecoder().decode(ReconstructionSourceEvaluation.self, from: payload)
        }
        catch { throw Failure.malformed }
        guard try encode(value) == payload else { throw Failure.noncanonical }
        try validate(value)
        return value
    }
    static func validate(_ value: ReconstructionSourceEvaluation) throws {
        guard let profile = try? ReconstructionSourceProfile.enabled(value.profileID),
              (try? profile.requirePayloadVersion(value.version)) != nil,
              value.function.image.architecture == .arm64, value.sourceEvidenceID != value.oracleEvidenceID else { throw Failure.invalidIdentity }
        let o = value.capturedOutcome
        let hashes = [value.evaluationRequestSHA256, value.sourcePayloadSHA256, value.revisionSHA256,
            value.sourceSHA256, value.sourceRequestSHA256, value.oraclePayloadSHA256, value.oracleSuiteSHA256,
            value.producerSHA256, value.evaluationSHA256, o.runnerSHA256, o.compilerSHA256,
            o.sdkSettingsSHA256, o.harnessSHA256] + [o.inspectionSHA256, o.astSHA256, o.executableSHA256].compactMap { $0 }
        for hash in hashes { try ReconstructionValidation.requireSHA256(hash, field: "source evaluation") }
        guard try canonicalIdentity(value) == value.evaluationSHA256 else { throw Failure.invalidIdentity }
        guard o.phases.count <= 3, o.phases.map(\.operation) == Array([ReconstructionSourceEvaluation.Operation.inspect, .compile, .behavior].prefix(o.phases.count)),
              Set(o.phases.map(\.requestID)).count == o.phases.count,
              Set(o.phases.map(\.sessionID)).count <= 1,
              o.failureDetail.map({ !$0.isEmpty && $0.utf8.count <= 2_048 && !$0.utf8.contains(0) }) ?? true else { throw Failure.invalidOutcome }
        func validTerminal(_ t: ReconstructionSourceEvaluation.Terminal) -> Bool {
            (t.kind == .exited || t.kind == .signaled) == (t.status != nil)
        }
        for (index, phase) in o.phases.enumerated() {
            try ReconstructionValidation.requireSHA256(phase.requestIdentitySHA256, field: "evaluation phase request")
            guard phase.diagnostics.count <= 16_384, phase.sampledProcessIDs.count <= 1_024,
                  Set(phase.sampledProcessIDs).count == phase.sampledProcessIDs.count,
                  phase.sampledProcessIDs.allSatisfy({ $0 > 1 }), phase.elapsedMilliseconds <= 60_000,
                  phase.failure.map({ !$0.isEmpty && $0.utf8.count <= 2_048 && !$0.utf8.contains(0) }) ?? true,
                  phase.terminal.map(validTerminal) ?? true else { throw Failure.invalidOutcome }
            if phase.status == .completed {
                guard let cleanup = phase.cleanup, cleanup.sessionID == phase.sessionID,
                      cleanup.requestID == phase.requestID, cleanup.processIdentifier > 1,
                      validTerminal(cleanup.outcome) else { throw Failure.invalidOutcome }
                if phase.failure == nil {
                    guard phase.sampledProcessIDs.contains(cleanup.processIdentifier), cleanup.observedProcessAbsent, phase.terminal != nil, cleanup.outcome == phase.terminal else { throw Failure.invalidOutcome }
                }
            } else {
                guard phase.failure != nil, phase.cleanup == nil, phase.terminal == nil else { throw Failure.invalidOutcome }
            }
            if index + 1 < o.phases.count {
                guard phase.status == .completed, phase.failure == nil,
                      phase.terminal == .init(kind: .exited, status: 0) else { throw Failure.invalidOutcome }
            }
        }
        let inputs = try profile.scalarInputs()
        guard o.observations.isEmpty || o.observations.map(\.input) == inputs,
              o.mismatches.count <= inputs.count, Set(o.mismatches.map(\.index)).count == o.mismatches.count,
              o.mismatches.map(\.index) == o.mismatches.map(\.index).sorted() else { throw Failure.invalidOutcome }
        for m in o.mismatches {
            guard o.observations.count == inputs.count, inputs.indices.contains(m.index), m.input == inputs[m.index],
                  m.actual == o.observations[m.index].output, m.expected != m.actual else { throw Failure.invalidOutcome }
        }
        switch o.status {
        case .accepted, .behaviorMismatch:
            guard o.phases.count == 3, o.inspectionSHA256 != nil, o.astSHA256 == o.inspectionSHA256,
                  o.executableSHA256 != nil, o.observations.count == inputs.count,
                  o.phases.allSatisfy({ $0.status == .completed && $0.failure == nil && $0.terminal == .init(kind: .exited, status: 0) }),
                  (o.status == .accepted ? o.mismatches.isEmpty : !o.mismatches.isEmpty),
                  (o.status != .accepted || o.failureDetail == nil) else { throw Failure.invalidOutcome }
        case .inspectionRejected, .invalidInspection:
            guard o.phases.count == 1, o.executableSHA256 == nil, o.observations.isEmpty, o.mismatches.isEmpty else { throw Failure.invalidOutcome }
        case .buildRejected, .invalidExecutable:
            guard o.phases.count == 2, o.astSHA256 != nil, o.inspectionSHA256 == o.astSHA256,
                  o.observations.isEmpty, o.mismatches.isEmpty else { throw Failure.invalidOutcome }
        case .behaviorRejected, .invalidBehaviorOutput:
            guard o.phases.count == 3, o.astSHA256 != nil, o.executableSHA256 != nil,
                  o.observations.isEmpty, o.mismatches.isEmpty else { throw Failure.invalidOutcome }
        case .cancelled, .transportFailed, .invalidAuthority, .changedInputs:
            guard o.mismatches.isEmpty else { throw Failure.invalidOutcome }
        }
    }
}
