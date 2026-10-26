import Foundation

extension ReconstructionDatabaseOwner {
    /// Reconstitutes only an already-completed reply's frozen prompt observation after its
    /// process-local native publication has gone away. It does not publish native analysis or
    /// mutate evidence. Every other semantic request field must still match, and Ready admission
    /// subsequently checks the complete prompt key and the freshly observed selected model.
    func historicalReplyPromptTransient(workspaceID: UUID, jobID: UUID, taskID: UUID,
        objective: ReconstructionRequestObjective, request: ReconstructionInferenceRoundRequest
    ) throws -> ReconstructionTransientAnalysis? {
        guard request.transientAnalysis == nil, request.jobID == jobID, objective.jobID == jobID else {
            throw ReconstructionReplayError.invalidScope
        }
        return try withActiveDatabase { database in
            guard try database.reconstructionWorkspaceID(containingJobID: jobID) == workspaceID else {
                throw ReconstructionReplayError.invalidScope
            }
            let records = try database.ownerReplayRecords(workspaceID: workspaceID)
                .filter { $0.identity.objectiveID == jobID && $0.identity.taskID == taskID
                    && $0.identity.requestKind == "roundR2" && $0.freshReply != nil }
            var retained: ReconstructionTransientAnalysis?
            for record in records {
                guard record.identity.objectiveSHA256 == objective.sha256,
                      let reply = record.freshReply else { continue }
                let original = try JSONDecoder().decode(ReconstructionInferenceRoundRequestR2.self,
                    from: reply.originalRequestBytes)
                guard original.objective == objective, let historical = original.request.transientAnalysis else { continue }
                try historical.validate(for: original.request)
                let bare = replacingTransient(original.request, with: nil)
                let current = ReconstructionAIWorkerRequest.roundR2(.init(protocolVersion: original.protocolVersion,
                    objective: objective, request: request))
                guard try ReconstructionPromptReplayIdentity.canonicalRequest(.roundR2(.init(
                    protocolVersion: original.protocolVersion, objective: objective, request: bare)))
                    == ReconstructionPromptReplayIdentity.canonicalRequest(current) else { continue }
                let rebound = ReconstructionTransientAnalysis(schemaVersion: historical.schemaVersion,
                    domain: historical.domain, jobID: historical.jobID, checkpointRevision: request.checkpointRevision,
                    corpusManifestSHA256: historical.corpusManifestSHA256,
                    evidenceFrontierSHA256: historical.evidenceFrontierSHA256, budgetBytes: historical.budgetBytes,
                    usedBytes: historical.usedBytes, facts: historical.facts, omissions: historical.omissions)
                try rebound.validate(for: replacingTransient(request, with: rebound))
                guard retained == nil || retained == rebound else { throw ReconstructionReplayError.staleAdmission }
                retained = rebound
            }
            return retained
        }
    }
}

private func replacingTransient(_ request: ReconstructionInferenceRoundRequest,
                               with transient: ReconstructionTransientAnalysis?) -> ReconstructionInferenceRoundRequest {
    .init(protocolVersion: request.protocolVersion, jobID: request.jobID,
        checkpointRevision: request.checkpointRevision, roundID: request.roundID,
        corpusManifestSHA256: request.corpusManifestSHA256, evidenceFrontierSHA256: request.evidenceFrontierSHA256,
        registryManifestSHA256: request.registryManifestSHA256, context: request.context, handles: request.handles,
        transientAnalysis: transient)
}

extension ReconstructionDatabaseOwner {
    /// Diagnostic only, called on a replay-key miss: names which identity fields and, for R2
    /// rounds, which canonical request fields differ between each published reply of the same
    /// job/kind and the current request. Values are digests or counts; prompt text never leaves.
    func replayMissDiagnostic(workspaceID: UUID, jobID: UUID, current identity: ReconstructionPromptReplayIdentity,
                              request: ReconstructionAIWorkerRequest, lease: Phase2ReadyInferenceLease,
                              scope: ReconstructionReplayScope, selectedModelIdentitySHA256: String) throws -> [String] {
        try withActiveDatabase { database in
            let records = try database.ownerReplayRecords(workspaceID: workspaceID)
                .filter { $0.identity.objectiveID == jobID && $0.identity.requestKind == identity.requestKind
                    && $0.freshReply != nil }
            return try records.map { record in
                var differing: [String] = []
                let prior = record.identity
                if prior.taskID != identity.taskID { differing.append("taskID") }
                if prior.logicalRoundIndex != identity.logicalRoundIndex {
                    differing.append("logicalRoundIndex(\(prior.logicalRoundIndex)->\(identity.logicalRoundIndex))")
                }
                if prior.objectiveSHA256 != identity.objectiveSHA256 { differing.append("objectiveSHA256") }
                if prior.modelIdentitySHA256 != identity.modelIdentitySHA256 { differing.append("modelIdentitySHA256") }
                if prior.canonicalPromptSHA256 != identity.canonicalPromptSHA256 { differing.append("canonicalPromptSHA256") }
                guard let reply = record.freshReply, identity.requestKind == "roundR2", case .roundR2 = request else {
                    return differing.joined(separator: ",")
                }
                let original = ReconstructionAIWorkerRequest.roundR2(try JSONDecoder().decode(
                    ReconstructionInferenceRoundRequestR2.self, from: reply.originalRequestBytes))
                // Same original request re-keyed with the CURRENT tool requests and model: if this
                // matches, the miss is in the tool requests/model, not the request preimage.
                let rekeyed = try? ReconstructionPromptReplayIdentity.make(request: original, lease: lease,
                    jobID: jobID, taskID: identity.taskID, logicalRoundIndex: identity.logicalRoundIndex,
                    objectiveSHA256: identity.objectiveSHA256, toolRequests: scope.toolRequests,
                    selectedModelIdentitySHA256: selectedModelIdentitySHA256)
                differing.append("rekeyedOriginalMatches=\(rekeyed?.canonicalPromptSHA256 == identity.canonicalPromptSHA256)")
                guard case .roundR2(let a) = try ReconstructionPromptReplayIdentity.canonicalRequest(original),
                      case .roundR2(let b) = try ReconstructionPromptReplayIdentity.canonicalRequest(request) else {
                    return differing.joined(separator: ",")
                }
                func digest<T: Encodable>(_ value: T) -> String {
                    (try? ReconstructionCanonicalJSON.sha256(of: value)).map { String($0.prefix(12)) } ?? "unencodable"
                }
                func compare<T: Encodable>(_ name: String, _ x: T, _ y: T) {
                    let dx = digest(x), dy = digest(y)
                    if dx != dy { differing.append("\(name)(\(dx)->\(dy))") }
                }
                compare("objective", a.objective, b.objective)
                compare("protocolVersion", a.protocolVersion, b.protocolVersion)
                compare("request.protocolVersion", a.request.protocolVersion, b.request.protocolVersion)
                compare("corpusManifestSHA256", a.request.corpusManifestSHA256, b.request.corpusManifestSHA256)
                compare("evidenceFrontierSHA256", a.request.evidenceFrontierSHA256, b.request.evidenceFrontierSHA256)
                compare("registryManifestSHA256", a.request.registryManifestSHA256, b.request.registryManifestSHA256)
                compare("context", a.request.context, b.request.context)
                compare("handles", a.request.handles, b.request.handles)
                compare("transientAnalysis", a.request.transientAnalysis, b.request.transientAnalysis)
                if let x = a.request.transientAnalysis, let y = b.request.transientAnalysis {
                    compare("transient.facts", x.facts, y.facts)
                    compare("transient.omissions", x.omissions, y.omissions)
                    compare("transient.frontier", x.evidenceFrontierSHA256, y.evidenceFrontierSHA256)
                    compare("transient.budget", [x.budgetBytes, x.usedBytes], [y.budgetBytes, y.usedBytes])
                }
                differing.append("originalFacts=\(a.request.transientAnalysis?.facts.count ?? -1)")
                differing.append("currentFacts=\(b.request.transientAnalysis?.facts.count ?? -1)")
                return differing.joined(separator: ",")
            }
        }
    }
}
