import Foundation

/// U09 increment 1: typed observations and a scoped per-case comparator over the existing scalar
/// oracle and evaluation records. Pure and in-memory: nothing here is persisted, and existing
/// evaluation statuses, mismatches and payload bytes are untouched.

/// Identities that must agree for two observation sets to be comparable at all. The comparable
/// subset mirrors the existing revision guard (harness, compiler, SDK). Other identities are
/// recorded when the source record has them and are never invented.
struct ReconstructionObservationEnvironment: Hashable, Codable, Sendable {
    let harnessSHA256: String
    let compilerSHA256: String
    let sdkIdentitySHA256: String
    let runnerSHA256: String?
    let executionArgumentsSHA256: String?

    func isComparable(with other: Self) -> Bool {
        harnessSHA256 == other.harnessSHA256
            && compilerSHA256 == other.compilerSHA256
            && sdkIdentitySHA256 == other.sdkIdentitySHA256
    }
}

/// The program state the cases ran from. The scalar v1 harness runs every case in one fresh
/// process, so cases are recorded as sharing it; independence is not claimed.
enum ReconstructionObservationState: Hashable, Codable, Sendable {
    case freshProcess(executableSHA256: String?, casesShareProcess: Bool)
}

/// One observable effect, in the order it occurred within a case.
enum ReconstructionObservationEffect: Hashable, Codable, Sendable {
    case returnValueU32(UInt32)
}

enum ReconstructionObservationValueCompleteness: Hashable, Codable, Sendable {
    enum Reason: String, Codable, Sendable {
        case notExecuted, behaviorOutputUnavailable
    }

    case complete
    case absent(Reason)
}

struct ReconstructionObservedCase: Hashable, Codable, Sendable {
    let ordinal: Int
    let input: UInt32
    let completeness: ReconstructionObservationValueCompleteness
    /// Ordered; empty exactly when the value is absent.
    let effects: [ReconstructionObservationEffect]
}

struct ReconstructionObservationSet: Hashable, Codable, Sendable {
    static let version = 1

    enum Side: String, Codable, Sendable {
        case original, candidate
    }

    /// Value consistency with the supplied oracle, not authenticated custody. The evidence
    /// owner must validate source records and current scope in one cut before production use.
    struct SourceBinding: Hashable, Codable, Sendable {
        let projectID: UUID
        let jobID: UUID
        let function: ReconstructionFunctionCoordinate
        let oracleEvidenceID: UUID
        let oraclePayloadSHA256: String
    }

    let version: Int
    let side: Side
    let contractID: String
    let contractVersion: Int
    let suiteSHA256: String
    /// The oracle or evaluation evidence the set was projected from.
    let sourceEvidenceID: UUID
    let binding: SourceBinding
    let environment: ReconstructionObservationEnvironment
    let state: ReconstructionObservationState
    let cases: [ReconstructionObservedCase]

    /// Memberwise construction and Codable do not establish this scalar shape.
    func validateShape(contract: ReconstructionObservationContract) throws {
        guard contract.isAdmitted, version == Self.version,
              contractID == contract.contractID, contractVersion == contract.version,
              !cases.isEmpty, cases.count <= contract.maximumCases else {
            throw ReconstructionObservationAdapterError.malformedObservations
        }
        for (index, value) in cases.enumerated() {
            guard value.ordinal == index else { throw ReconstructionObservationAdapterError.malformedObservations }
            switch value.completeness {
            case .complete:
                guard value.effects.count == 1 else { throw ReconstructionObservationAdapterError.malformedObservations }
            case .absent:
                guard value.effects.isEmpty else { throw ReconstructionObservationAdapterError.malformedObservations }
            }
        }
        let executable: String?
        switch state { case .freshProcess(let digest, _): executable = digest }
        for digest in [suiteSHA256, binding.oraclePayloadSHA256, environment.harnessSHA256,
            environment.compilerSHA256, environment.sdkIdentitySHA256]
            + [environment.runnerSHA256, environment.executionArgumentsSHA256, executable].compactMap({ $0 }) {
            do { try ReconstructionValidation.requireSHA256(digest, field: "observation identity") }
            catch { throw ReconstructionObservationAdapterError.malformedObservations }
        }
    }

    var usesScalarProcessState: Bool {
        switch state { case .freshProcess(_, let casesShareProcess): casesShareProcess }
    }

    var canonicalSHA256: String {
        get throws { try ReconstructionCanonicalJSON.sha256(of: self) }
    }
}

enum ReconstructionObservationAdapterError: Error, Equatable, Sendable {
    case unadmittedContract
    case profileMismatch
    case suiteMismatch
    case sourceBindingMismatch
    /// Cancelled, transport-failed, unauthorized or changed-input evaluations observed nothing.
    case noObservation(ReconstructionSourceEvaluation.Status)
    case malformedObservations
}

/// Read-only projection of existing records. Values come only from the records themselves;
/// callers pass records already validated by their owners (oracle admission, evaluation codec).
/// Canonical hashes and supplied evidence IDs establish value consistency only. These adapters
/// do not authenticate records, attest process execution, or authorize production comparison.
enum ReconstructionObservationAdapter {
    static func original(
        _ oracle: ReconstructionSourceOracle,
        evidenceID: UUID,
        contract: ReconstructionObservationContract
    ) throws -> ReconstructionObservationSet {
        guard contract.isAdmitted else { throw ReconstructionObservationAdapterError.unadmittedContract }
        guard oracle.profileID == contract.sourceProfileID, oracle.version == contract.oracleVersion else {
            throw ReconstructionObservationAdapterError.profileMismatch
        }
        guard !oracle.inputs.isEmpty, oracle.inputs.count == oracle.outputs.count,
              oracle.inputs.count <= contract.maximumCases else {
            throw ReconstructionObservationAdapterError.malformedObservations
        }
        let execution = oracle.execution
        let result = ReconstructionObservationSet(version: ReconstructionObservationSet.version, side: .original,
            contractID: contract.contractID, contractVersion: contract.version, suiteSHA256: oracle.suiteSHA256,
            sourceEvidenceID: evidenceID,
            binding: .init(projectID: oracle.projectID, jobID: oracle.jobID, function: oracle.function,
                oracleEvidenceID: evidenceID,
                oraclePayloadSHA256: try ReconstructionSourceRevisionAdmission.sourceSHA256(ReconstructionCanonicalJSON.encode(oracle))),
            environment: .init(harnessSHA256: execution.harnessSHA256, compilerSHA256: execution.compilerSHA256,
                sdkIdentitySHA256: execution.sdkIdentitySHA256, runnerSHA256: nil,
                executionArgumentsSHA256: execution.executionArgumentsSHA256),
            state: .freshProcess(executableSHA256: execution.originalExecutableSHA256, casesShareProcess: true),
            cases: zip(oracle.inputs, oracle.outputs).enumerated().map { ordinal, pair in
                ReconstructionObservedCase(ordinal: ordinal, input: pair.0, completeness: .complete,
                                           effects: [.returnValueU32(pair.1)])
            })
        try result.validateShape(contract: contract)
        return result
    }

    /// `original` supplies case inputs only when the evaluation names the same oracle suite, so an
    /// absent candidate value is still attributed to the exact input it would have observed.
    static func candidate(
        _ evaluation: ReconstructionSourceEvaluation,
        evidenceID: UUID,
        original: ReconstructionObservationSet,
        contract: ReconstructionObservationContract
    ) throws -> ReconstructionObservationSet {
        guard contract.isAdmitted else { throw ReconstructionObservationAdapterError.unadmittedContract }
        guard evaluation.version == ReconstructionSourceEvaluation.version,
              evaluation.profileID == contract.sourceProfileID, original.contractID == contract.contractID,
              original.contractVersion == contract.version, original.side == .original,
              original.version == ReconstructionObservationSet.version else {
            throw ReconstructionObservationAdapterError.profileMismatch
        }
        guard evaluation.oracleSuiteSHA256 == original.suiteSHA256,
              evaluation.oracleEvidenceID == original.sourceEvidenceID else {
            throw ReconstructionObservationAdapterError.suiteMismatch
        }
        try original.validateShape(contract: contract)
        guard evidenceID != original.sourceEvidenceID,
              evaluation.projectID == original.binding.projectID, evaluation.jobID == original.binding.jobID,
              evaluation.function == original.binding.function,
              evaluation.oracleEvidenceID == original.binding.oracleEvidenceID,
              evaluation.oraclePayloadSHA256 == original.binding.oraclePayloadSHA256 else {
            throw ReconstructionObservationAdapterError.sourceBindingMismatch
        }
        let outcome = evaluation.capturedOutcome
        let inputs = original.cases.map(\.input)
        let cases: [ReconstructionObservedCase]
        switch outcome.status {
        case .accepted, .behaviorMismatch:
            guard outcome.observations.count == inputs.count else {
                throw ReconstructionObservationAdapterError.malformedObservations
            }
            cases = outcome.observations.enumerated().map { ordinal, observation in
                ReconstructionObservedCase(ordinal: ordinal, input: observation.input, completeness: .complete,
                                           effects: [.returnValueU32(observation.output)])
            }
        case .behaviorRejected, .invalidBehaviorOutput:
            cases = absent(inputs, reason: .behaviorOutputUnavailable)
        case .inspectionRejected, .buildRejected, .invalidInspection, .invalidExecutable:
            cases = absent(inputs, reason: .notExecuted)
        case .cancelled, .transportFailed, .invalidAuthority, .changedInputs:
            throw ReconstructionObservationAdapterError.noObservation(outcome.status)
        }
        let result = ReconstructionObservationSet(version: ReconstructionObservationSet.version, side: .candidate,
            contractID: contract.contractID, contractVersion: contract.version,
            suiteSHA256: evaluation.oracleSuiteSHA256, sourceEvidenceID: evidenceID,
            binding: original.binding,
            environment: .init(harnessSHA256: outcome.harnessSHA256, compilerSHA256: outcome.compilerSHA256,
                sdkIdentitySHA256: outcome.sdkSettingsSHA256, runnerSHA256: outcome.runnerSHA256,
                executionArgumentsSHA256: nil),
            state: .freshProcess(executableSHA256: outcome.executableSHA256, casesShareProcess: true),
            cases: cases)
        try result.validateShape(contract: contract)
        return result
    }

    private static func absent(
        _ inputs: [UInt32],
        reason: ReconstructionObservationValueCompleteness.Reason
    ) -> [ReconstructionObservedCase] {
        inputs.enumerated().map {
            ReconstructionObservedCase(ordinal: $0.offset, input: $0.element, completeness: .absent(reason), effects: [])
        }
    }
}

enum ReconstructionObservationVerdict: Hashable, Codable, Sendable {
    enum Reason: String, Codable, Sendable {
        case environment, inputIdentity, caseCount, state
    }

    case equal
    case differs(expected: [ReconstructionObservationEffect], actual: [ReconstructionObservationEffect])
    case incomplete(ReconstructionObservationSet.Side)
    case incomparable(Reason)
}

/// One scoped comparison. Each verdict is computed from its own case pair only.
struct ReconstructionObservationComparison: Hashable, Codable, Sendable {
    static let comparatorID = "reconstruction.observation.compare.v1"

    struct CaseVerdict: Hashable, Codable, Sendable {
        let ordinal: Int
        let input: UInt32
        let verdict: ReconstructionObservationVerdict
    }

    let comparatorID: String
    let scopeSHA256: String
    let contractID: String
    let scenarioOracleEvidenceID: UUID
    let scenarioRole: ReconstructionFeatureScenario.Role
    let originalSetSHA256: String
    let candidateSetSHA256: String
    let cases: [CaseVerdict]

    var canonicalSHA256: String {
        get throws { try ReconstructionCanonicalJSON.sha256(of: self) }
    }

    var isEquivalent: Bool { !cases.isEmpty && cases.allSatisfy { $0.verdict == .equal } }
}

/// Pure comparison. The caller supplies an already authenticated scope and currency; `.current`
/// alone is not owner authority. The production receipt author projects only its final round cut.
enum ReconstructionObservationComparator {
    enum Failure: Error, Equatable, Sendable {
        case staleScope([UUID])
        case unadmittedContract
        case contractNotScoped
        case scenarioNotScoped
        case suiteMismatch
        case sideMismatch
        case sourceBindingMismatch
        case malformedObservations
    }

    static func compare(
        scope: ReconstructionFeatureScope,
        currency: ReconstructionFeatureScopeCurrency,
        original: ReconstructionObservationSet,
        candidate: ReconstructionObservationSet
    ) throws -> ReconstructionObservationComparison {
        if case .stale(let ids) = currency { throw Failure.staleScope(ids) }
        let contract = scope.observationContract
        guard contract.isAdmitted else { throw Failure.unadmittedContract }
        guard original.contractID == contract.contractID, candidate.contractID == contract.contractID,
              original.contractVersion == contract.version, candidate.contractVersion == contract.version else {
            throw Failure.contractNotScoped
        }
        guard original.side == .original, candidate.side == .candidate else { throw Failure.sideMismatch }
        guard original.version == ReconstructionObservationSet.version,
              candidate.version == ReconstructionObservationSet.version else { throw Failure.contractNotScoped }
        guard let scenario = scope.scenarios.first(where: { $0.oracleEvidenceID == original.sourceEvidenceID }) else {
            throw Failure.scenarioNotScoped
        }
        guard scenario.suiteSHA256 == original.suiteSHA256, candidate.suiteSHA256 == original.suiteSHA256 else {
            throw Failure.suiteMismatch
        }

        guard candidate.sourceEvidenceID != original.sourceEvidenceID,
              original.binding == candidate.binding,
              original.binding.projectID == scope.projectID, original.binding.jobID == scope.jobID,
              original.binding.function == scope.feature,
              original.binding.oracleEvidenceID == original.sourceEvidenceID else {
            throw Failure.sourceBindingMismatch
        }
        do {
            try original.validateShape(contract: contract)
            try candidate.validateShape(contract: contract)
        } catch { throw Failure.malformedObservations }

        let setReason: ReconstructionObservationVerdict.Reason?
        if !original.environment.isComparable(with: candidate.environment) {
            setReason = .environment
        } else if !original.usesScalarProcessState || !candidate.usesScalarProcessState {
            setReason = .state
        } else if original.cases.count != candidate.cases.count || original.cases.count != scenario.caseCount {
            setReason = .caseCount
        } else {
            setReason = nil
        }
        let verdicts = original.cases.enumerated().map { index, expected -> ReconstructionObservationComparison.CaseVerdict in
            let verdict: ReconstructionObservationVerdict
            if let setReason {
                verdict = .incomparable(setReason)
            } else {
                verdict = Self.verdict(expected: expected, actual: candidate.cases[index])
            }
            return .init(ordinal: expected.ordinal, input: expected.input, verdict: verdict)
        }
        return .init(comparatorID: ReconstructionObservationComparison.comparatorID,
            scopeSHA256: scope.canonicalSHA256, contractID: contract.contractID,
            scenarioOracleEvidenceID: scenario.oracleEvidenceID, scenarioRole: scenario.role,
            originalSetSHA256: try original.canonicalSHA256, candidateSetSHA256: try candidate.canonicalSHA256,
            cases: verdicts)
    }

    private static func verdict(
        expected: ReconstructionObservedCase,
        actual: ReconstructionObservedCase
    ) -> ReconstructionObservationVerdict {
        guard expected.ordinal == actual.ordinal, expected.input == actual.input else {
            return .incomparable(.inputIdentity)
        }
        if case .absent = expected.completeness { return .incomplete(.original) }
        if case .absent = actual.completeness { return .incomplete(.candidate) }
        return expected.effects == actual.effects ? .equal : .differs(expected: expected.effects, actual: actual.effects)
    }
}
