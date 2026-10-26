import Darwin
import Foundation

protocol ReconstructionSourceOriginalRecovering: Sendable {
    func session(for basis: ReconstructionProductionRoundBasis) async throws -> ReconstructionSourceOriginalSession?
    func retire() async
}

/// Unavailability is recoverable by the existing job owner. Authority violations remain distinct;
/// callers must not turn either error into an invented source result or tool receipt.
enum ReconstructionSourceOriginalRecoveryFailure: Error, Equatable, Sendable, LocalizedError {
    case unavailable(String)
    case authorityMismatch
    case retired
    var errorDescription: String? {
        switch self {
        case .unavailable(let diagnostic): diagnostic
        case .authorityMismatch: "The original source recovery does not match the committed job authority."
        case .retired: "The original source recovery has been retired."
        }
    }
}

/// Job-scoped recovery of the explicit fixed source intent. It never recompiles: the original
/// executable is recovered from the job's durably retained attachment bytes (the executable the job
/// already admitted as evidence), verified against the admitted SHA-256, installed into a fresh
/// original stage and bound to the existing import without importing again or manufacturing a
/// function. Historical compiler identity is never inferred from a match.
actor ReconstructionSourceOriginalRecovery: ReconstructionSourceOriginalRecovering {
    typealias WorkflowProvider = @Sendable () async throws -> ReconstructionSourceExecutionWorkflow
    private struct Key: Equatable, Sendable {
        let workspaceID: UUID
        let projectID: UUID
        let jobID: UUID
        let artifact: ReconstructionArtifactCoordinate
    }
    private struct Active {
        let id: UUID
        let task: Task<ReconstructionSourceOriginalSession, Error>
    }
    private let workflowProvider: WorkflowProvider
    private let stageParent: URL
    private let registry: ReconstructionSourceOriginalSessionRegistry
    private var key: Key?
    private var active: Active?
    private var lastSession: ReconstructionSourceOriginalSession?
    private var retired = false
    private static let maximumExecutableBytes = 1_048_576

    init(workflowProvider: @escaping WorkflowProvider, stageParent: URL,
         registry: ReconstructionSourceOriginalSessionRegistry = .shared) {
        self.workflowProvider = workflowProvider; self.stageParent = stageParent; self.registry = registry
    }

    /// Retains actual preparation phases/cleanup on a failed recovery, without publishing evidence.
    func preparationDiagnostic() async -> ReconstructionSourceExecutionWorkflow.PreparedOriginal? {
        await lastSession?.preparationDiagnostic()
    }

    func session(for basis: ReconstructionProductionRoundBasis) async throws -> ReconstructionSourceOriginalSession? {
        guard !retired else { throw ReconstructionSourceOriginalRecoveryFailure.retired }
        try Task.checkCancellation()
        guard basis.job.sourceProfileID != nil, !basis.job.state.isTerminal else { return nil }
        guard basis.job.sourceProfileID == ReconstructionSourceExecutionTaskContract.profileID,
              case .artifact(let artifact)? = basis.job.focus,
              basis.job.reconstructionProjectID == basis.project.projectID,
              basis.freshnessAuthority.currentArtifacts.contains(artifact),
              basis.manifest.artifacts.contains(where: {
                  $0.occurrenceID == artifact.occurrenceID && $0.contentIdentity == artifact.contentIdentity
              }) else { throw ReconstructionSourceOriginalRecoveryFailure.authorityMismatch }
        let proposed = Key(workspaceID: basis.workspaceID, projectID: basis.project.projectID,
                           jobID: basis.job.jobID, artifact: artifact)
        guard key == nil || key == proposed else { throw ReconstructionSourceOriginalRecoveryFailure.authorityMismatch }
        key = proposed
        if try Self.hasCommittedOracle(basis: basis, artifact: artifact) { return nil }
        let sources = basis.attachmentSources.filter { $0.contentIdentity == artifact.contentIdentity }
        guard sources.count == 1, let source = sources.first else {
            throw ReconstructionSourceOriginalRecoveryFailure.authorityMismatch
        }
        let operation: Active
        if let current = active { operation = current }
        else {
            let provider = workflowProvider, parent = stageParent, registry = registry
            operation = .init(id: UUID(), task: Task {
                try await Self.resolve(key: proposed, source: source, provider: provider,
                    parent: parent, registry: registry, recordSession: { session in
                        await self.recordSession(session)
                    })
            })
            active = operation
        }
        do {
            let session = try await withTaskCancellationHandler {
                try await operation.task.value
            } onCancel: { operation.task.cancel() }
            if active?.id == operation.id { active = nil }
            guard !retired else { throw ReconstructionSourceOriginalRecoveryFailure.retired }
            try Task.checkCancellation()
            return session
        } catch {
            if active?.id == operation.id { active = nil }
            if retired { throw ReconstructionSourceOriginalRecoveryFailure.retired }
            throw error
        }
    }

    func retire() async {
        retired = true
        let operation = active?.task
        operation?.cancel()
        // Await the original workflow's terminal cleanup before retiring the registered session.
        _ = try? await operation?.value
        if let key { await registry.remove(workspaceID: key.workspaceID, jobID: key.jobID) }
        await lastSession?.retire()
        active = nil
    }
    private func recordSession(_ session: ReconstructionSourceOriginalSession) { lastSession = session }

    private static func resolve(key: Key, source: ReconstructionAttachmentSource,
        provider: WorkflowProvider, parent: URL, registry: ReconstructionSourceOriginalSessionRegistry,
        recordSession: @Sendable (ReconstructionSourceOriginalSession) async -> Void) async throws -> ReconstructionSourceOriginalSession {
        let retained = try verifyAttachment(source)
        if let existing = await registry.session(workspaceID: key.workspaceID, jobID: key.jobID) {
            await recordSession(existing)
            do { try await existing.bind(projectID: key.projectID, jobID: key.jobID, importedArtifact: key.artifact) }
            catch { throw mapSessionError(error) }
            try Task.checkCancellation()
            return existing
        }
        let workflow: ReconstructionSourceExecutionWorkflow
        do { workflow = try await provider() }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            throw unavailable("Original source tooling is unavailable: " + String(describing: error))
        }
        try Task.checkCancellation()
        let created = ReconstructionSourceOriginalSession(workflow: workflow, stageParent: parent)
        await recordSession(created)
        var registered = false
        do {
            let candidate = try await created.prepareRetained(executable: retained,
                expectedSHA256: key.artifact.contentIdentity.digest)
            try Task.checkCancellation()
            _ = try verifyAttachment(source)
            // Exact-byte guard: the recovered candidate is the admitted executable, byte for byte.
            guard candidate.profileID == ReconstructionSourceOriginalSession.sourceProfile.rawValue,
                  candidate.sourceSHA256 == ReconstructionSourceRevisionAdmission.sourceSHA256(ReconstructionSourceOriginalSession.originalSourceUTF8),
                  candidate.executable.sha256 == key.artifact.contentIdentity.digest,
                  UInt64(candidate.executable.byteCount) == key.artifact.contentIdentity.byteCount else {
                throw unavailable("The recovered original executable does not match the admitted executable's exact SHA-256 and byte count.")
            }
            try await created.bind(projectID: key.projectID, jobID: key.jobID, importedArtifact: key.artifact)
            try Task.checkCancellation()
            // Another authorized lookup may have installed the same job's session while preparing.
            if let existing = await registry.session(workspaceID: key.workspaceID, jobID: key.jobID) {
                try await existing.bind(projectID: key.projectID, jobID: key.jobID, importedArtifact: key.artifact)
                await created.retire()
                await recordSession(existing)
                try Task.checkCancellation()
                return existing
            }
            try await registry.register(workspaceID: key.workspaceID, jobID: key.jobID, session: created)
            registered = true
            try Task.checkCancellation()
            return created
        } catch {
            if registered { await registry.remove(workspaceID: key.workspaceID, jobID: key.jobID) }
            await created.retire()
            try Task.checkCancellation()
            if error is CancellationError { throw CancellationError() }
            if let typed = error as? ReconstructionSourceOriginalRecoveryFailure { throw typed }
            throw mapSessionError(error)
        }
    }

    private static func hasCommittedOracle(basis: ReconstructionProductionRoundBasis,
                                            artifact: ReconstructionArtifactCoordinate) throws -> Bool {
        let records = basis.evidenceCut.records.filter {
            $0.creatingJobID == basis.job.jobID && $0.operationID == ReconstructionSourceOracleEvidence.operationID
                && basis.evidenceCut.projectedClassificationsByEvidenceID[$0.evidenceID] == .acceptedCurrent
        }
        guard records.count <= 1 else { throw ReconstructionSourceOriginalRecoveryFailure.authorityMismatch }
        guard let record = records.first else { return false }
        guard case .function(let function) = record.subject, function.artifact == artifact,
              basis.freshnessAuthority.currentImages.contains(where: {
                  $0.artifact == artifact && $0.image == function.image
                      && $0.analysisFingerprintSHA256 == function.analysisFingerprintSHA256
              }) else { throw ReconstructionSourceOriginalRecoveryFailure.authorityMismatch }
        do { _ = try ReconstructionProductionSourceAuthority.committedOracle(function: function, basis: basis) }
        catch { throw ReconstructionSourceOriginalRecoveryFailure.authorityMismatch }
        return true
    }

    /// Returns the retained bytes read from one stable descriptor window, verified against the
    /// admitted SHA-256 and byte count.
    @discardableResult
    private static func verifyAttachment(_ source: ReconstructionAttachmentSource) throws -> Data {
        try Task.checkCancellation()
        guard source.contentIdentity.algorithm == .sha256, source.contentIdentity.byteCount > 0,
              source.contentIdentity.byteCount <= UInt64(maximumExecutableBytes) else {
            throw ReconstructionSourceOriginalRecoveryFailure.authorityMismatch
        }
        let descriptor: Int32
        do { descriptor = try source.openVerifiedDescriptor() }
        catch { throw unavailable("The imported original executable cannot be opened for recovery.") }
        guard descriptor >= 0 else { throw unavailable("The imported original executable is unavailable for recovery.") }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == getuid(), before.st_nlink == 1, before.st_size > 0,
              UInt64(before.st_size) == source.contentIdentity.byteCount else {
            throw ReconstructionSourceOriginalRecoveryFailure.authorityMismatch
        }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw unavailable("The imported original executable could not be read for recovery.") }
            if count == 0 { break }
            guard bytes.count + count <= maximumExecutableBytes else {
                throw ReconstructionSourceOriginalRecoveryFailure.authorityMismatch
            }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_mode == after.st_mode, before.st_uid == after.st_uid, after.st_nlink == 1,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              UInt64(bytes.count) == source.contentIdentity.byteCount,
              ReconstructionSourceRevisionAdmission.sourceSHA256(bytes) == source.contentIdentity.digest else {
            throw ReconstructionSourceOriginalRecoveryFailure.authorityMismatch
        }
        if !source.hasDescriptorAuthority {
            var path = stat()
            guard lstat(source.verifiedURL.path, &path) == 0, (path.st_mode & S_IFMT) == S_IFREG,
                  path.st_dev == after.st_dev, path.st_ino == after.st_ino else {
                throw ReconstructionSourceOriginalRecoveryFailure.authorityMismatch
            }
        }
        try Task.checkCancellation()
        return bytes
    }

    private static func mapSessionError(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if (error as? ReconstructionProductionReceiptPlanAuthorError) == .invalidCommittedAuthority {
            return ReconstructionSourceOriginalRecoveryFailure.authorityMismatch
        }
        if let failure = error as? ReconstructionSourceOriginalSession.Failure {
            switch failure {
            case .invalidBinding, .uncommittedFunction: return ReconstructionSourceOriginalRecoveryFailure.authorityMismatch
            case .preparationFailed(.invalidAuthority), .preparationFailed(.changedInputs):
                return ReconstructionSourceOriginalRecoveryFailure.authorityMismatch
            default: break
            }
        }
        if let failure = error as? ReconstructionSourceExecutionStage.Failure {
            switch failure {
            case .writeFailed: return unavailable("The private original preparation stage could not be written.")
            default: return ReconstructionSourceOriginalRecoveryFailure.authorityMismatch
            }
        }
        return unavailable("The original source preparation is unavailable: " + String(describing: error))
    }
    private static func unavailable(_ text: String) -> ReconstructionSourceOriginalRecoveryFailure {
        var bounded = String(decoding: text.utf8.prefix(1_024), as: UTF8.self)
        while bounded.utf8.count > 1_024 { bounded.removeLast() }
        return .unavailable(bounded)
    }
}
