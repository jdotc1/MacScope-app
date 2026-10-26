import Foundation

/// One explicit app-owned source intent. This transient session owns preparation lifetime only;
/// import, committed analysis, oracle publication and checkpoints retain their existing owners.
actor ReconstructionSourceOriginalSession {
    struct ImportCandidate: Sendable {
        let executableURL: URL
        let executable: ReconstructionSourceExecutionStage.FileIdentity
        let sourceSHA256: String
        let harnessSHA256: String
        let profileID: String
    }
    enum Failure: Error, Equatable, Sendable {
        case busy, retired, notPrepared, invalidBinding, uncommittedFunction
        case preparationFailed(ReconstructionSourceExecutionWorkflow.Failure)
    }
    private struct Binding: Equatable, Sendable {
        let projectID: UUID
        let jobID: UUID
        let artifact: ReconstructionArtifactCoordinate
    }
    private struct Active: Sendable {
        let id: UUID
        let task: Task<ReconstructionSourceExecutionWorkflow.PreparedOriginal, Never>
    }
    private let workflow: ReconstructionSourceExecutionWorkflow
    private let stageParent: URL
    private var active: Active?
    private var prepared: ReconstructionSourceExecutionWorkflow.PreparedOriginal?
    private var binding: Binding?
    private var retired = false

    init(workflow: ReconstructionSourceExecutionWorkflow, stageParent: URL) {
        self.workflow = workflow
        self.stageParent = stageParent
    }

    /// Fixed owner-selected target; neither source bytes nor the expected outputs come from a model.
    static let sourceProfile = ReconstructionSourceProfile.scalarU32V1
    static let originalSourceUTF8 = Data("""
    typedef unsigned int uint32_t;
    uint32_t reconstructed(uint32_t value) { return value == 4294967295U ? value : value + 1U; }

    """.utf8)

    func prepare() async throws -> ImportCandidate {
        try await prepare(retained: nil)
    }

    /// Resume recovery: never recompiles. Installs the job's durably admitted original executable
    /// (already verified against `expectedSHA256` by the caller) into a fresh original stage.
    func prepareRetained(executable: Data, expectedSHA256: String) async throws -> ImportCandidate {
        try await prepare(retained: (executable, expectedSHA256))
    }

    private func prepare(retained: (bytes: Data, sha256: String)?) async throws -> ImportCandidate {
        guard !retired else { throw Failure.retired }
        guard active == nil else { throw Failure.busy }
        try Task.checkCancellation()
        if let prepared { return try candidate(prepared) }
        let harness = try ReconstructionSourceBehaviorHarness.forProfile(Self.sourceProfile.rawValue)
        let source = Self.originalSourceUTF8
        let stage = try ReconstructionSourceExecutionStage.createOriginalAuthority(sourceUTF8: source,
            expectedSourceSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(source),
            harness: harness, parent: stageParent, profileID: Self.sourceProfile.rawValue)
        let id = UUID()
        let operation = Task { [workflow] in
            if let retained {
                return await workflow.prepareRetainedOriginal(stage: stage, retainedExecutable: retained.bytes,
                                                              expectedSHA256: retained.sha256)
            }
            return await workflow.prepareOriginal(stage: stage)
        }
        active = .init(id: id, task: operation)
        let result = await withTaskCancellationHandler {
            await operation.value
        } onCancel: { operation.cancel() }
        if active?.id == id { active = nil }
        // Keep actual phases available even when preparation was rejected or cancellation observed.
        prepared = result
        guard !retired else { throw Failure.retired }
        try Task.checkCancellation()
        return try candidate(result)
    }

    /// Called only after ordinary corpus import and job creation. Content binding cannot be changed
    /// to another occurrence or job later, even when the compiled bytes happen to be identical.
    func bind(projectID: UUID, jobID: UUID, importedArtifact: ReconstructionArtifactCoordinate) throws {
        guard !retired else { throw Failure.retired }
        guard let prepared, active == nil else { throw Failure.notPrepared }
        let candidate = try candidate(prepared)
        guard importedArtifact.contentIdentity.algorithm == .sha256,
              importedArtifact.contentIdentity.digest == candidate.executable.sha256,
              importedArtifact.contentIdentity.byteCount == UInt64(candidate.executable.byteCount) else {
            throw Failure.invalidBinding
        }
        let proposed = Binding(projectID: projectID, jobID: jobID, artifact: importedArtifact)
        guard binding == nil || binding == proposed else { throw Failure.invalidBinding }
        binding = proposed
    }

    /// `committedFunctions` must be captured by the database owner from the same production cut as
    /// the task. This helper never manufactures a coordinate or treats a name hint as authority.
    func preparedOriginal(projectID: UUID, jobID: UUID, function: ReconstructionFunctionCoordinate,
                          committedFunctions: [ReconstructionFunctionCoordinate]) throws
        -> ReconstructionSourceExecutionWorkflow.PreparedOriginal {
        guard !retired else { throw Failure.retired }
        guard let prepared, let binding, active == nil else { throw Failure.notPrepared }
        guard binding.projectID == projectID, binding.jobID == jobID,
              binding.artifact == function.artifact,
              function.image.architecture == .arm64,
              ReconstructionReboundFunctionAuthority.expectedFunctionID(for: function) != nil else {
            throw Failure.invalidBinding
        }
        guard committedFunctions.contains(function) else { throw Failure.uncommittedFunction }
        _ = try candidate(prepared)
        return prepared
    }

    func preparationDiagnostic() -> ReconstructionSourceExecutionWorkflow.PreparedOriginal? { prepared }

    func retire() async {
        retired = true
        let operation = active?.task
        operation?.cancel()
        // The existing workflow and broker observe process cleanup before this task resolves.
        _ = await operation?.value
        binding = nil
    }

    private func candidate(_ prepared: ReconstructionSourceExecutionWorkflow.PreparedOriginal) throws -> ImportCandidate {
        if let failure = prepared.failure { throw Failure.preparationFailed(failure) }
        guard prepared.stage.profileID == Self.sourceProfile.rawValue, prepared.hasPreparationPhases,
              prepared.toolAuthority == workflow.toolAuthority,
              case .trustedOriginal(let sourceSHA256) = prepared.stage.sourceAuthority,
              sourceSHA256 == ReconstructionSourceRevisionAdmission.sourceSHA256(Self.originalSourceUTF8),
              let executable = prepared.executable else { throw Failure.invalidBinding }
        try prepared.stage.verifyExecutable(executable)
        return .init(executableURL: prepared.stage.root.appendingPathComponent("output/candidate"),
            executable: executable, sourceSHA256: sourceSHA256,
            harnessSHA256: prepared.stage.harness.sha256,
            profileID: prepared.stage.profileID)
    }
}
