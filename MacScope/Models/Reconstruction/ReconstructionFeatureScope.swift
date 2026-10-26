import Foundation

/// U06: what an admitted feature promises to observe. Closed set; v1 admits only the existing
/// scalar profile, whose limits are the existing oracle and harness constants, never new ones.
struct ReconstructionObservationContract: Hashable, Codable, Sendable {
    enum Channel: String, Codable, Sendable {
        case returnValueU32
    }

    enum Completeness: String, Codable, Sendable {
        case everyValueComplete
    }

    let contractID: String
    let version: Int
    let sourceProfileID: String
    let oracleVersion: Int
    let harnessVersion: Int
    let maximumCases: Int
    let channels: [Channel]
    let completeness: Completeness

    static let scalarU32ReturnV1 = ReconstructionObservationContract(
        contractID: "reconstruction.observation.scalar-u32-return.v1",
        version: 1,
        sourceProfileID: ReconstructionSourceOracle.profileID,
        oracleVersion: ReconstructionSourceOracle.version,
        harnessVersion: ReconstructionSourceBehaviorHarness.version,
        maximumCases: ReconstructionSourceBehaviorHarness.maximumCases,
        channels: [.returnValueU32],
        completeness: .everyValueComplete
    )

    static let admittedContracts: [ReconstructionObservationContract] = [scalarU32ReturnV1]

    var isAdmitted: Bool { Self.admittedContracts.contains(self) }
}

/// One accepted original-program observation bound to the scope. Holdout roles are reserved for
/// U12 and are deliberately unrepresentable here.
struct ReconstructionFeatureScenario: Hashable, Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case development
    }

    let oracleEvidenceID: UUID
    let suiteSHA256: String
    let caseCount: Int
    let role: Role
}

/// A declared dependency of the feature and how the scope treats it. Every declaration cites
/// accepted evidence; nothing is inferred from names or rendered pseudocode.
struct ReconstructionFeatureDependency: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case callee, global, importedSymbol
    }

    enum Disposition: String, Codable, Sendable {
        case inScope, modeledExternal, unsupported
    }

    let kind: Kind
    let subject: ReconstructionSubjectCoordinate?
    let symbol: String?
    let disposition: Disposition
    let evidenceIDs: [UUID]
}

enum ReconstructionFeatureScopeError: Error, Equatable, Sendable {
    case invalidShape(String)
    case unadmittedContract
    case digestMismatch
}

/// Immutable admitted feature coordinates for one reconstruction job. Persisted inside the job
/// record (job schema 6); a job without a scope keeps its schema-5 bytes unchanged.
struct ReconstructionFeatureScope: Hashable, Sendable {
    static let schemaVersion = 1
    static let maximumEvidence = 64
    static let maximumScenarios = 16
    static let maximumDependencies = 64

    let schemaVersion: Int
    let projectID: UUID
    let jobID: UUID
    /// v1 admits exactly one function.
    let feature: ReconstructionFunctionCoordinate
    let acceptedEvidenceIDs: [UUID]
    let scenarios: [ReconstructionFeatureScenario]
    let dependencies: [ReconstructionFeatureDependency]
    /// Evidence cited for the declaration; an empty dependency list does not prove independence.
    let dependencyBasisEvidenceIDs: [UUID]
    let observationContract: ReconstructionObservationContract
    let admittedAtCheckpointID: UUID
    let admittedAtCheckpointRevision: UInt64
    let admittedAtCheckpointSHA256: String
    let evidenceFrontierSHA256: String
    let canonicalSHA256: String

    private struct Preimage: Encodable {
        let schemaVersion: Int
        let projectID: UUID
        let jobID: UUID
        let feature: ReconstructionFunctionCoordinate
        let acceptedEvidenceIDs: [UUID]
        let scenarios: [ReconstructionFeatureScenario]
        let dependencies: [ReconstructionFeatureDependency]
        let dependencyBasisEvidenceIDs: [UUID]
        let observationContract: ReconstructionObservationContract
        let admittedAtCheckpointID: UUID
        let admittedAtCheckpointRevision: UInt64
        let admittedAtCheckpointSHA256: String
        let evidenceFrontierSHA256: String
    }

    /// Canonicalizes ordering and computes the digest. Shape is validated here; whether the cited
    /// evidence is accepted and current is the database owner's admission responsibility.
    static func make(
        projectID: UUID,
        jobID: UUID,
        feature: ReconstructionFunctionCoordinate,
        acceptedEvidenceIDs: [UUID],
        scenarios: [ReconstructionFeatureScenario],
        dependencies: [ReconstructionFeatureDependency],
        dependencyBasisEvidenceIDs: [UUID],
        observationContract: ReconstructionObservationContract,
        admittedAtCheckpointID: UUID,
        admittedAtCheckpointRevision: UInt64,
        admittedAtCheckpointSHA256: String,
        evidenceFrontierSHA256: String
    ) throws -> Self {
        let canonicalDependencies = try dependencies.map {
            ReconstructionFeatureDependency(kind: $0.kind, subject: $0.subject, symbol: $0.symbol,
                disposition: $0.disposition, evidenceIDs: ReconstructionValidation.sortedUUIDs($0.evidenceIDs))
        }.map { (try ReconstructionCanonicalJSON.encode($0), $0) }
            .sorted { $0.0.lexicographicallyPrecedes($1.0) }
            .map { $0.1 }
        let preimage = Preimage(
            schemaVersion: schemaVersion, projectID: projectID, jobID: jobID, feature: feature,
            acceptedEvidenceIDs: ReconstructionValidation.sortedUUIDs(acceptedEvidenceIDs),
            scenarios: scenarios.sorted { $0.oracleEvidenceID.uuidString < $1.oracleEvidenceID.uuidString },
            dependencies: canonicalDependencies,
            dependencyBasisEvidenceIDs: ReconstructionValidation.sortedUUIDs(dependencyBasisEvidenceIDs),
            observationContract: observationContract,
            admittedAtCheckpointID: admittedAtCheckpointID,
            admittedAtCheckpointRevision: admittedAtCheckpointRevision,
            admittedAtCheckpointSHA256: admittedAtCheckpointSHA256,
            evidenceFrontierSHA256: evidenceFrontierSHA256)
        return try Self(preimage: preimage, canonicalSHA256: ReconstructionCanonicalJSON.sha256(of: preimage))
    }

    private init(preimage: Preimage, canonicalSHA256: String) throws {
        schemaVersion = preimage.schemaVersion
        projectID = preimage.projectID
        jobID = preimage.jobID
        feature = preimage.feature
        acceptedEvidenceIDs = preimage.acceptedEvidenceIDs
        scenarios = preimage.scenarios
        dependencies = preimage.dependencies
        dependencyBasisEvidenceIDs = preimage.dependencyBasisEvidenceIDs
        observationContract = preimage.observationContract
        admittedAtCheckpointID = preimage.admittedAtCheckpointID
        admittedAtCheckpointRevision = preimage.admittedAtCheckpointRevision
        admittedAtCheckpointSHA256 = preimage.admittedAtCheckpointSHA256
        evidenceFrontierSHA256 = preimage.evidenceFrontierSHA256
        self.canonicalSHA256 = canonicalSHA256
        try validateShape()
        guard try ReconstructionCanonicalJSON.sha256(of: preimage) == canonicalSHA256 else {
            throw ReconstructionFeatureScopeError.digestMismatch
        }
    }

    private func validateShape() throws {
        func fail(_ field: String) -> ReconstructionFeatureScopeError { .invalidShape(field) }
        guard schemaVersion == Self.schemaVersion else { throw fail("schema") }
        guard observationContract.isAdmitted else { throw ReconstructionFeatureScopeError.unadmittedContract }
        try ReconstructionValidation.requireSHA256(admittedAtCheckpointSHA256, field: "scope checkpoint digest")
        try ReconstructionValidation.requireSHA256(evidenceFrontierSHA256, field: "scope evidence frontier")
        let accepted = Set(acceptedEvidenceIDs)
        guard !acceptedEvidenceIDs.isEmpty, acceptedEvidenceIDs.count <= Self.maximumEvidence,
              accepted.count == acceptedEvidenceIDs.count,
              acceptedEvidenceIDs == ReconstructionValidation.sortedUUIDs(acceptedEvidenceIDs) else {
            throw fail("accepted evidence")
        }
        guard !scenarios.isEmpty, scenarios.count <= Self.maximumScenarios,
              Set(scenarios.map(\.oracleEvidenceID)).count == scenarios.count,
              scenarios.allSatisfy({
                  accepted.contains($0.oracleEvidenceID)
                      && $0.caseCount > 0 && $0.caseCount <= observationContract.maximumCases
                      && (try? ReconstructionValidation.requireSHA256($0.suiteSHA256, field: "suite")) != nil
              }) else {
            throw fail("scenarios")
        }
        guard !dependencyBasisEvidenceIDs.isEmpty,
              Set(dependencyBasisEvidenceIDs).count == dependencyBasisEvidenceIDs.count,
              dependencyBasisEvidenceIDs.allSatisfy(accepted.contains) else {
            throw fail("dependency basis")
        }
        guard dependencies.count <= Self.maximumDependencies,
              Set(dependencies).count == dependencies.count,
              dependencies.allSatisfy({ dependency in
                  (dependency.subject != nil || dependency.symbol != nil)
                      && dependency.symbol.map { !$0.isEmpty && $0.utf8.count <= 256 } != false
                      && !dependency.evidenceIDs.isEmpty
                      && Set(dependency.evidenceIDs).count == dependency.evidenceIDs.count
                      && dependency.evidenceIDs.allSatisfy(accepted.contains)
              }) else {
            throw fail("dependencies")
        }
    }

    /// Historical structural binding only. Currency and retained receipt authority are checked
    /// separately against the current cut; stale evidence does not erase this declaration.
    func validateScenarioBindings(recordsByID: [UUID: ReconstructionEvidenceRecord]) throws {
        for scenario in scenarios {
            guard let record = recordsByID[scenario.oracleEvidenceID],
                  record.operationID == "reconstruction.source.oracle",
                  record.creatingJobID == jobID, record.subject == .function(feature),
                  let oracle = try? Self.decodeHistoricalOracle(record.payload),
                  oracle.version == observationContract.oracleVersion,
                  oracle.profileID == observationContract.sourceProfileID,
                  oracle.projectID == projectID, oracle.jobID == jobID, oracle.function == feature,
                  oracle.suiteSHA256 == scenario.suiteSHA256,
                  oracle.inputs.count == scenario.caseCount, oracle.outputs.count == scenario.caseCount,
                  Set(oracle.evidenceIDs).isSubset(of: Set(acceptedEvidenceIDs)) else {
                throw ReconstructionFeatureScopeError.invalidShape("scenario binding")
            }
        }
    }

    // AnalysisCore cannot depend on the app's receipt-admission bridge. Validate the typed
    // payload and its suite commitment here; live admission still uses that bridge to validate
    // execution, task and receipt authority. This helper grants no current execution authority.
    private static func decodeHistoricalOracle(_ payload: Data) throws -> ReconstructionSourceOracle {
        struct SuitePreimage: Encodable {
            let version: Int
            let profileID: String
            let projectID: UUID
            let jobID: UUID
            let function: ReconstructionFunctionCoordinate
            let inputs: [UInt32]
            let outputs: [UInt32]
            let execution: ReconstructionSourceOracle.Execution
            let evidenceIDs: [UUID]
        }
        guard !payload.isEmpty, payload.count <= ReconstructionSourceOracle.maximumPayloadBytes else {
            throw ReconstructionFeatureScopeError.invalidShape("oracle payload bounds")
        }
        let oracle = try JSONDecoder().decode(ReconstructionSourceOracle.self, from: payload)
        let harness = try ReconstructionSourceBehaviorHarness.forProfile(oracle.profileID)
        let preimage = SuitePreimage(version: oracle.version, profileID: oracle.profileID,
            projectID: oracle.projectID, jobID: oracle.jobID, function: oracle.function,
            inputs: oracle.inputs, outputs: oracle.outputs, execution: oracle.execution, evidenceIDs: oracle.evidenceIDs)
        guard try ReconstructionCanonicalJSON.encode(oracle) == payload,
              oracle.version == ReconstructionSourceOracle.version,
              ReconstructionSourceProfile.admits(oracle.profileID),
              oracle.inputs == harness.inputs,
              oracle.outputs == (try harness.decodeObservedOutputs(oracle.execution.standardOutput)),
              !oracle.evidenceIDs.isEmpty, oracle.evidenceIDs.count <= Self.maximumEvidence,
              Set(oracle.evidenceIDs).count == oracle.evidenceIDs.count,
              oracle.evidenceIDs == ReconstructionValidation.sortedUUIDs(oracle.evidenceIDs),
              oracle.suiteSHA256 == (try ReconstructionCanonicalJSON.sha256(of: preimage)) else {
            throw ReconstructionFeatureScopeError.invalidShape("oracle suite commitment")
        }
        return oracle
    }

    /// Artifact declarations only; these coordinates make no claim of independence.
    var declaredArtifacts: Set<ReconstructionArtifactCoordinate> {
        Set(dependencies.compactMap { dependency in
            switch dependency.subject {
            case .artifact(let artifact): return artifact
            case .image(let image): return image.artifact
            case .function(let function): return function.artifact
            case nil: return nil
            }
        })
    }

    /// Every evidence ID the scope cites, for admission and currency checks.
    var citedEvidenceIDs: Set<UUID> {
        Set(acceptedEvidenceIDs)
    }
}

extension ReconstructionFeatureScope: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, projectID, jobID, feature, acceptedEvidenceIDs, scenarios, dependencies
        case dependencyBasisEvidenceIDs, observationContract, admittedAtCheckpointID
        case admittedAtCheckpointRevision, admittedAtCheckpointSHA256, evidenceFrontierSHA256, canonicalSHA256
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: values,
                debugDescription: "unsupported feature scope schema \(version)")
        }
        try self.init(preimage: Preimage(
            schemaVersion: version,
            projectID: values.decode(UUID.self, forKey: .projectID),
            jobID: values.decode(UUID.self, forKey: .jobID),
            feature: values.decode(ReconstructionFunctionCoordinate.self, forKey: .feature),
            acceptedEvidenceIDs: values.decode([UUID].self, forKey: .acceptedEvidenceIDs),
            scenarios: values.decode([ReconstructionFeatureScenario].self, forKey: .scenarios),
            dependencies: values.decode([ReconstructionFeatureDependency].self, forKey: .dependencies),
            dependencyBasisEvidenceIDs: values.decode([UUID].self, forKey: .dependencyBasisEvidenceIDs),
            observationContract: values.decode(ReconstructionObservationContract.self, forKey: .observationContract),
            admittedAtCheckpointID: values.decode(UUID.self, forKey: .admittedAtCheckpointID),
            admittedAtCheckpointRevision: values.decode(UInt64.self, forKey: .admittedAtCheckpointRevision),
            admittedAtCheckpointSHA256: values.decode(String.self, forKey: .admittedAtCheckpointSHA256),
            evidenceFrontierSHA256: values.decode(String.self, forKey: .evidenceFrontierSHA256)),
            canonicalSHA256: values.decode(String.self, forKey: .canonicalSHA256))
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(projectID, forKey: .projectID)
        try values.encode(jobID, forKey: .jobID)
        try values.encode(feature, forKey: .feature)
        try values.encode(acceptedEvidenceIDs, forKey: .acceptedEvidenceIDs)
        try values.encode(scenarios, forKey: .scenarios)
        try values.encode(dependencies, forKey: .dependencies)
        try values.encode(dependencyBasisEvidenceIDs, forKey: .dependencyBasisEvidenceIDs)
        try values.encode(observationContract, forKey: .observationContract)
        try values.encode(admittedAtCheckpointID, forKey: .admittedAtCheckpointID)
        try values.encode(admittedAtCheckpointRevision, forKey: .admittedAtCheckpointRevision)
        try values.encode(admittedAtCheckpointSHA256, forKey: .admittedAtCheckpointSHA256)
        try values.encode(evidenceFrontierSHA256, forKey: .evidenceFrontierSHA256)
        try values.encode(canonicalSHA256, forKey: .canonicalSHA256)
    }
}

/// Whether an admitted scope still describes current evidence. Consumers (U09/U10) must refuse a
/// stale scope rather than re-admitting silently.
enum ReconstructionFeatureScopeCurrency: Equatable, Sendable {
    case current
    case stale([UUID])

    static func of(
        _ scope: ReconstructionFeatureScope,
        classifications: [UUID: ReconstructionEvidenceClassification]
    ) -> Self {
        let stale = scope.acceptedEvidenceIDs.filter { classifications[$0] != .acceptedCurrent }
        return stale.isEmpty ? .current : .stale(stale)
    }
}
