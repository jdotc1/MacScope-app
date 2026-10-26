import Foundation

/// Explicit, transient preparation intent. Durable oracle/source/evaluation evidence remains the
/// restoration authority after publication; this registry never changes a job or writes a package.
actor ReconstructionSourceOriginalSessionRegistry {
    static let shared = ReconstructionSourceOriginalSessionRegistry()
    private struct Entry { let workspaceID: UUID; let session: ReconstructionSourceOriginalSession }
    private var sessions: [UUID: Entry] = [:]
    func register(workspaceID: UUID, jobID: UUID, session: ReconstructionSourceOriginalSession) throws {
        guard sessions[jobID] == nil else { throw ReconstructionProductionReceiptPlanAuthorError.invalidCommittedAuthority }
        sessions[jobID] = .init(workspaceID: workspaceID, session: session)
    }
    func session(workspaceID: UUID, jobID: UUID) -> ReconstructionSourceOriginalSession? {
        guard let entry = sessions[jobID], entry.workspaceID == workspaceID else { return nil }
        return entry.session
    }
    func remove(workspaceID: UUID, jobID: UUID) async {
        guard let entry = sessions[jobID], entry.workspaceID == workspaceID else { return }
        sessions.removeValue(forKey: jobID)
        await entry.session.retire()
    }
    func retire(workspaceID: UUID) async {
        let entries = sessions.filter { $0.value.workspaceID == workspaceID }
        for key in entries.keys { sessions.removeValue(forKey: key) }
        for entry in entries.values { await entry.session.retire() }
    }

    private struct Projection: Decodable {
        struct Value: Decodable { let function: FunctionSummary? }
        let projection: Value?
    }
    static func committedFunctions(in basis: ReconstructionProductionRoundBasis) -> [ReconstructionFunctionCoordinate] {
        basis.evidenceCut.records.compactMap { record in
            guard record.creatingJobID == basis.job.jobID,
                  record.operationID == ReconstructionOperationID.decompilerMacScope.rawValue,
                  basis.evidenceCut.projectedClassificationsByEvidenceID[record.evidenceID] == .acceptedCurrent,
                  case .function(let coordinate) = record.subject,
                  basis.tasks.contains(where: { $0.identity.taskID == record.creatingTaskID
                    && $0.identity.kind == .decompileMacScope && $0.state == .completed
                    && $0.identity.subject == record.subject }) else { return nil }
            return coordinate
        }
    }
    func targetFunction(in basis: ReconstructionProductionRoundBasis) async throws -> ReconstructionFunctionCoordinate? {
        guard let session = session(workspaceID: basis.workspaceID, jobID: basis.job.jobID) else { return nil }
        let committed = Self.committedFunctions(in: basis)
        let targets = basis.evidenceCut.records.compactMap { record -> ReconstructionFunctionCoordinate? in
            guard record.creatingJobID == basis.job.jobID,
                  record.operationID == ReconstructionOperationID.decompilerMacScope.rawValue,
                  basis.evidenceCut.projectedClassificationsByEvidenceID[record.evidenceID] == .acceptedCurrent,
                  case .function(let coordinate) = record.subject, committed.contains(coordinate),
                  let projection = try? JSONDecoder().decode(Projection.self, from: record.payload),
                  let function = projection.projection?.function,
                  function.name == "reconstructed" || function.name == "_reconstructed",
                  ReconstructionReboundFunctionAuthority.matches(function, coordinate: coordinate) else { return nil }
            return coordinate
        }
        let unique = Set(targets)
        guard unique.count <= 1 else { throw ReconstructionProductionReceiptPlanAuthorError.invalidCommittedAuthority }
        guard let function = unique.first else { return nil }
        _ = try await session.preparedOriginal(projectID: basis.project.projectID, jobID: basis.job.jobID,
            function: function, committedFunctions: committed)
        return function
    }
}
