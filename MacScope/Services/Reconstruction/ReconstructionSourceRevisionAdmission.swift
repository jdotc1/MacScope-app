import CryptoKit
import Foundation

enum ReconstructionSourceRevisionAdmission {
    enum Failure: Error, Equatable {
        case unsupportedVersion, unsupportedProfile, unsafePath, sourceBounds, invalidUTF8
        case sourceHashMismatch, staleParent, authorityMismatch, invalidEvidenceReferences
        case revisionHashMismatch, noncanonicalPayload, payloadBounds, invalidTarget, revisionLimit
        case invalidRequestBinding
    }

    static func sourceSHA256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func admit(
        proposal: ReconstructionSourceRevisionProposal,
        authority: ReconstructionSourceRevisionAuthority
    ) throws -> ReconstructionSourceRevision {
        try Task.checkCancellation()
        try validateAuthority(authority)
        guard proposal.version == ReconstructionSourceRevision.contractVersion else { throw Failure.unsupportedVersion }
        guard ReconstructionSourceProfile.admits(proposal.profileID) else { throw Failure.unsupportedProfile }
        guard proposal.profileID == authority.profileID else { throw Failure.authorityMismatch }
        guard proposal.relativePath == "candidate.c" else { throw Failure.unsafePath }
        guard !proposal.sourceUTF8.isEmpty,
              proposal.sourceUTF8.count <= ReconstructionSourceRevision.maximumSourceBytes else { throw Failure.sourceBounds }
        guard String(data: proposal.sourceUTF8, encoding: .utf8) != nil,
              !proposal.sourceUTF8.contains(0) else { throw Failure.invalidUTF8 }
        let sourceHash = sourceSHA256(proposal.sourceUTF8)
        guard sourceHash == proposal.claimedSourceSHA256 else { throw Failure.sourceHashMismatch }
        guard proposal.parentRevisionSHA256 == authority.currentRevision?.revisionSHA256 else { throw Failure.staleParent }
        guard authority.currentRevision?.parentRevisionSHA256 == nil else { throw Failure.revisionLimit }
        guard !proposal.evidenceIDs.isEmpty,
              proposal.evidenceIDs.count <= ReconstructionSourceRevision.maximumEvidenceReferences,
              Set(proposal.evidenceIDs).count == proposal.evidenceIDs.count,
              Set(proposal.evidenceIDs).isSubset(of: authority.admissibleEvidenceIDs) else { throw Failure.invalidEvidenceReferences }
        if let binding = authority.requestBinding {
            let offered = try validateRequestBinding(binding, authority: authority)
            guard Set(proposal.evidenceIDs).isSubset(of: offered) else { throw Failure.invalidEvidenceReferences }
        }
        let function = try canonicalFunction(authority.function)
        let preimage = Preimage(version: proposal.version, projectID: authority.projectID, jobID: authority.jobID,
            function: function, objectiveSHA256: authority.objectiveSHA256,
            evidenceFrontierSHA256: authority.evidenceFrontierSHA256, oracleSuiteSHA256: authority.oracleSuiteSHA256,
            profileID: proposal.profileID, parentRevisionSHA256: proposal.parentRevisionSHA256,
            relativePath: proposal.relativePath, sourceUTF8: proposal.sourceUTF8, sourceSHA256: sourceHash,
            evidenceIDs: ReconstructionValidation.sortedUUIDs(proposal.evidenceIDs), status: .proposed, requestBinding: authority.requestBinding)
        let revision = preimage.revision(hash: try ReconstructionCanonicalJSON.sha256(of: preimage))
        _ = try encode(revision)
        return revision
    }

    /// Consumer entry point for hostile persisted/model bytes, not bare JSONDecoder admission.
    /// Exact canonical equality rejects unknown/duplicate keys, alternative encodings and hints.
    static func decodeAndValidate(
        payload: Data,
        authority: ReconstructionSourceRevisionAuthority
    ) throws -> ReconstructionSourceRevision {
        try Task.checkCancellation()
        guard !payload.isEmpty, payload.count <= ReconstructionSourceRevision.maximumPayloadBytes else { throw Failure.payloadBounds }
        let decoded = try JSONDecoder().decode(ReconstructionSourceRevision.self, from: payload)
        guard decoded.projectID == authority.projectID, decoded.jobID == authority.jobID,
              decoded.function == authority.function,
              decoded.objectiveSHA256 == authority.objectiveSHA256,
              decoded.evidenceFrontierSHA256 == authority.evidenceFrontierSHA256,
              decoded.oracleSuiteSHA256 == authority.oracleSuiteSHA256,
              decoded.requestBinding == authority.requestBinding else { throw Failure.authorityMismatch }
        let rebuilt = try admit(proposal: .init(version: decoded.version, profileID: decoded.profileID,
            parentRevisionSHA256: decoded.parentRevisionSHA256, relativePath: decoded.relativePath,
            sourceUTF8: decoded.sourceUTF8, claimedSourceSHA256: decoded.sourceSHA256,
            evidenceIDs: decoded.evidenceIDs), authority: authority)
        guard rebuilt.revisionSHA256 == decoded.revisionSHA256 else { throw Failure.revisionHashMismatch }
        guard try encode(rebuilt) == payload else { throw Failure.noncanonicalPayload }
        return rebuilt
    }

    static func encode(_ revision: ReconstructionSourceRevision) throws -> Data {
        let bytes = try ReconstructionCanonicalJSON.encode(revision)
        guard bytes.count <= ReconstructionSourceRevision.maximumPayloadBytes else { throw Failure.payloadBounds }
        return bytes
    }

    static func makeRequestBinding(canonicalRequestBytes: Data, requestSHA256: String,
        authority: ReconstructionSourceRevisionAuthority, expectedTaskID: UUID, expectedRoundID: UUID,
        expectedCheckpointRevision: UInt64) throws -> ReconstructionSourceRequestBinding {
        let binding = ReconstructionSourceRequestBinding(canonicalRequestBytes: canonicalRequestBytes,
            requestSHA256: requestSHA256, taskID: expectedTaskID, roundID: expectedRoundID,
            checkpointRevision: expectedCheckpointRevision)
        _ = try validateRequestBinding(binding, authority: authority)
        return binding
    }

    @discardableResult
    static func validateRequestBinding(_ binding: ReconstructionSourceRequestBinding,
        authority: ReconstructionSourceRevisionAuthority) throws -> Set<UUID> {
        try validateBinding(binding, authority: authority, expectedParent: authority.currentRevision?.revisionSHA256)
    }

    private struct NeutralObjective: Codable {
        let sourceProfileID: String?
        let jobID: UUID
        let text: String
        let sha256: String
    }
    private struct NeutralContext: Codable {
        let canonicalBytes: Data
        let canonicalSHA256: String
        let evidenceIDs: [UUID]
        let allowedGapSubjects: [String]
        let allowedGapCategories: [String]
        let allowedGapIDs: [UUID]
    }
    private struct NeutralRequest: Codable {
        let protocolVersion: Int
        let objective: NeutralObjective
        let projectID: UUID
        let jobID: UUID
        let taskID: UUID
        let checkpointRevision: UInt64
        let roundID: UUID
        let function: ReconstructionFunctionCoordinate
        let corpusManifestSHA256: String
        let evidenceFrontierSHA256: String
        let oracleSuiteSHA256: String
        let profileID: String
        let parentRevisionSHA256: String?
        let context: NeutralContext
    }
    private static func decodeNeutralRequest(_ binding: ReconstructionSourceRequestBinding) throws -> NeutralRequest {
        guard !binding.canonicalRequestBytes.isEmpty,
              binding.canonicalRequestBytes.count <= ReconstructionSourceRequestBinding.maximumRequestBytes,
              sourceSHA256(binding.canonicalRequestBytes) == binding.requestSHA256 else { throw Failure.invalidRequestBinding }
        let request: NeutralRequest
        do { request = try JSONDecoder().decode(NeutralRequest.self, from: binding.canonicalRequestBytes) }
        catch { throw Failure.invalidRequestBinding }
        guard try ReconstructionCanonicalJSON.encode(request) == binding.canonicalRequestBytes else { throw Failure.invalidRequestBinding }
        return request
    }
    private static func validateBinding(_ binding: ReconstructionSourceRequestBinding,
        authority: ReconstructionSourceRevisionAuthority, expectedParent: String?) throws -> Set<UUID> {
        let request = try decodeNeutralRequest(binding), context = request.context
        guard request.protocolVersion == 10, request.projectID == authority.projectID,
              request.jobID == authority.jobID, request.objective.jobID == authority.jobID,
              request.objective.sourceProfileID.map({ $0 == authority.profileID }) ?? true,
              request.taskID == binding.taskID, request.roundID == binding.roundID,
              request.checkpointRevision == binding.checkpointRevision,
              request.function == authority.function,
              request.objective.sha256 == authority.objectiveSHA256,
              !request.objective.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.objective.text.utf8.count <= 4_096, !request.objective.text.utf8.contains(0),
              sourceSHA256(Data(request.objective.text.utf8)) == request.objective.sha256,
              request.evidenceFrontierSHA256 == authority.evidenceFrontierSHA256,
              request.oracleSuiteSHA256 == authority.oracleSuiteSHA256,
              request.profileID == authority.profileID,
              ReconstructionSourceProfile.inferenceProfile(protocolVersion: request.protocolVersion)?.rawValue == authority.profileID,
              request.parentRevisionSHA256 == expectedParent,
              !context.canonicalBytes.isEmpty,
              context.canonicalBytes.count <= ReconstructionSourceRequestBinding.maximumContextBytes,
              sourceSHA256(context.canonicalBytes) == context.canonicalSHA256,
              !context.evidenceIDs.isEmpty, context.evidenceIDs.count <= 64,
              Set(context.evidenceIDs).count == context.evidenceIDs.count,
              Set(context.evidenceIDs).isSubset(of: authority.admissibleEvidenceIDs),
              context.allowedGapIDs.isEmpty, context.allowedGapSubjects.isEmpty,
              context.allowedGapCategories.isEmpty else { throw Failure.invalidRequestBinding }
        for digest in [request.corpusManifestSHA256, request.evidenceFrontierSHA256,
            request.oracleSuiteSHA256, context.canonicalSHA256] {
            try ReconstructionValidation.requireSHA256(digest, field: "source request binding")
        }
        if let parent = expectedParent { try ReconstructionValidation.requireSHA256(parent, field: "source request parent") }
        let contextObject: Any
        do { contextObject = try JSONSerialization.jsonObject(with: context.canonicalBytes) }
        catch { throw Failure.invalidRequestBinding }
        guard JSONSerialization.isValidJSONObject(contextObject),
              try JSONSerialization.data(withJSONObject: contextObject, options: [.sortedKeys, .withoutEscapingSlashes]) == context.canonicalBytes else {
            throw Failure.invalidRequestBinding
        }
        return Set(context.evidenceIDs)
    }

    private static func canonicalFunction(_ function: ReconstructionFunctionCoordinate) throws -> ReconstructionFunctionCoordinate {
        try .init(artifact: function.artifact, image: function.image,
            analysisFingerprintSHA256: function.analysisFingerprintSHA256, startAddress: function.startAddress,
            endAddressExclusive: function.endAddressExclusive, boundarySchemaVersion: function.boundarySchemaVersion,
            functionUUIDHint: nil, symbolHint: nil)
    }

    private static func validateAuthority(_ authority: ReconstructionSourceRevisionAuthority) throws {
        guard ReconstructionSourceProfile.admits(authority.profileID) else { throw Failure.unsupportedProfile }
        guard authority.function.image.architecture == .arm64,
              authority.function.image.selectedSliceIndex.map({ $0 >= 0 }) ?? true else { throw Failure.invalidTarget }
        for (field, digest) in [("source objective", authority.objectiveSHA256),
            ("source frontier", authority.evidenceFrontierSHA256), ("source oracle", authority.oracleSuiteSHA256)] {
            try ReconstructionValidation.requireSHA256(digest, field: field)
        }
        _ = try canonicalFunction(authority.function)
        if let binding = authority.requestBinding { _ = try validateRequestBinding(binding, authority: authority) }
        if let current = authority.currentRevision {
            guard current.projectID == authority.projectID, current.jobID == authority.jobID,
                  current.function == authority.function, current.objectiveSHA256 == authority.objectiveSHA256,
                  current.oracleSuiteSHA256 == authority.oracleSuiteSHA256,
                  current.profileID == authority.profileID else { throw Failure.authorityMismatch }
            if let parent = current.parentRevisionSHA256 {
                try ReconstructionValidation.requireSHA256(parent, field: "source parent revision")
            }
            try ReconstructionValidation.requireSHA256(current.evidenceFrontierSHA256, field: "source parent frontier")
            if let binding = current.requestBinding {
                let historical = ReconstructionSourceRevisionAuthority(projectID: current.projectID, jobID: current.jobID,
                    function: current.function, objectiveSHA256: current.objectiveSHA256,
                    evidenceFrontierSHA256: current.evidenceFrontierSHA256, oracleSuiteSHA256: current.oracleSuiteSHA256,
                    admissibleEvidenceIDs: Set(try decodeNeutralRequest(binding).context.evidenceIDs), currentRevision: nil,
                    profileID: authority.profileID)
                let offered = try validateBinding(binding, authority: historical, expectedParent: current.parentRevisionSHA256)
                guard Set(current.evidenceIDs).isSubset(of: offered) else { throw Failure.invalidEvidenceReferences }
            }
            // A caller-supplied current revision cannot establish parent authority with a forged hash.
            guard current.version == ReconstructionSourceRevision.contractVersion,
                  current.relativePath == "candidate.c", !current.evidenceIDs.isEmpty,
                  current.evidenceIDs.count <= ReconstructionSourceRevision.maximumEvidenceReferences,
                  Set(current.evidenceIDs).count == current.evidenceIDs.count,
                  current.evidenceIDs == ReconstructionValidation.sortedUUIDs(current.evidenceIDs),
                  current.function.functionUUIDHint == nil, current.function.symbolHint == nil,
                  !current.sourceUTF8.isEmpty,
                  current.sourceUTF8.count <= ReconstructionSourceRevision.maximumSourceBytes,
                  String(data: current.sourceUTF8, encoding: .utf8) != nil, !current.sourceUTF8.contains(0),
                  sourceSHA256(current.sourceUTF8) == current.sourceSHA256,
                  try ReconstructionCanonicalJSON.sha256(of: Preimage(current)) == current.revisionSHA256 else {
                throw Failure.revisionHashMismatch
            }
        }
    }

    private struct Preimage: Encodable {
        let version: Int
        let projectID: UUID
        let jobID: UUID
        let function: ReconstructionFunctionCoordinate
        let objectiveSHA256: String
        let evidenceFrontierSHA256: String
        let oracleSuiteSHA256: String
        let profileID: String
        let parentRevisionSHA256: String?
        let relativePath: String
        let sourceUTF8: Data
        let sourceSHA256: String
        let evidenceIDs: [UUID]
        let status: ReconstructionSourceRevision.Status
        let requestBinding: ReconstructionSourceRequestBinding?

        init(version: Int, projectID: UUID, jobID: UUID, function: ReconstructionFunctionCoordinate,
             objectiveSHA256: String, evidenceFrontierSHA256: String, oracleSuiteSHA256: String,
             profileID: String, parentRevisionSHA256: String?, relativePath: String, sourceUTF8: Data,
             sourceSHA256: String, evidenceIDs: [UUID], status: ReconstructionSourceRevision.Status,
             requestBinding: ReconstructionSourceRequestBinding? = nil) {
            self.version = version; self.projectID = projectID; self.jobID = jobID; self.function = function
            self.objectiveSHA256 = objectiveSHA256; self.evidenceFrontierSHA256 = evidenceFrontierSHA256
            self.oracleSuiteSHA256 = oracleSuiteSHA256; self.profileID = profileID
            self.parentRevisionSHA256 = parentRevisionSHA256; self.relativePath = relativePath
            self.sourceUTF8 = sourceUTF8; self.sourceSHA256 = sourceSHA256; self.evidenceIDs = evidenceIDs; self.status = status; self.requestBinding = requestBinding
        }
        init(_ r: ReconstructionSourceRevision) {
            self.init(version: r.version, projectID: r.projectID, jobID: r.jobID, function: r.function,
                objectiveSHA256: r.objectiveSHA256, evidenceFrontierSHA256: r.evidenceFrontierSHA256,
                oracleSuiteSHA256: r.oracleSuiteSHA256, profileID: r.profileID, parentRevisionSHA256: r.parentRevisionSHA256,
                relativePath: r.relativePath, sourceUTF8: r.sourceUTF8, sourceSHA256: r.sourceSHA256,
                evidenceIDs: r.evidenceIDs, status: r.status, requestBinding: r.requestBinding)
        }
        func revision(hash: String) -> ReconstructionSourceRevision {
            .init(version: version, projectID: projectID, jobID: jobID, function: function,
                objectiveSHA256: objectiveSHA256, evidenceFrontierSHA256: evidenceFrontierSHA256,
                oracleSuiteSHA256: oracleSuiteSHA256, profileID: profileID, parentRevisionSHA256: parentRevisionSHA256,
                relativePath: relativePath, sourceUTF8: sourceUTF8, sourceSHA256: sourceSHA256,
                evidenceIDs: evidenceIDs, status: status, revisionSHA256: hash, requestBinding: requestBinding)
        }
    }
}
