import CryptoKit
import Foundation

/// Bounded, in-memory summary of one admitted native-decompiler result. It is derived from the
/// validated execution when the batch result is admitted and retains no DTO bytes, structured
/// records, workspace snapshot, database or package reference. It is deliberately not Codable:
/// a publication can only be presented transiently and can never become durable truth.
struct ReconstructionTransientNativePublication: Equatable, Sendable {
    let workspaceID: UUID
    let jobID: UUID
    let taskID: UUID
    let taskKind: ReconstructionTaskKind
    let subject: ReconstructionFunctionCoordinate
    let checkpointRevision: UInt64
    let corpusManifestSHA256: String
    let generation: UInt64

    // Exact identity the native admission validated.
    let executionImageSlot: ImageSlot
    let executionFunctionID: UUID
    let executionAnalysisInputFingerprintSHA256: String
    let wireFunctionID: String
    let wireEntryAddress: UInt64
    let wireEndAddressExclusive: UInt64
    let providerIdentitySHA256: String
    let nativeRequestID: UUID
    let nativeRequestSHA256: String
    let nativeImageID: String
    let nativeImageUUID: UUID

    // Bounded semantics.
    let functionName: String
    let pseudocodeLanguage: String?
    let pseudocode: String?
    let pseudocodeWasTruncated: Bool
    let callTargets: [String]
    let variableNames: [String]
    let blockCount: Int
    let callCount: Int
    let variableCount: Int
    let warningCodes: [String]

    init(
        workspaceID: UUID,
        jobID: UUID,
        taskID: UUID,
        taskKind: ReconstructionTaskKind,
        subject: ReconstructionFunctionCoordinate,
        checkpointRevision: UInt64,
        corpusManifestSHA256: String,
        generation: UInt64,
        execution: NativeDecompilerValidatedExecution
    ) throws {
        typealias Fact = ReconstructionTransientNativeFact
        let result = execution.success.result
        self.workspaceID = workspaceID
        self.jobID = jobID
        self.taskID = taskID
        self.taskKind = taskKind
        self.subject = subject
        self.checkpointRevision = checkpointRevision
        self.corpusManifestSHA256 = corpusManifestSHA256
        self.generation = generation
        executionImageSlot = execution.imageSlot
        executionFunctionID = execution.functionID
        executionAnalysisInputFingerprintSHA256 = execution.analysisInputFingerprintSHA256
        wireFunctionID = Self.bounded(result.function.functionID, Fact.maximumNameUTF8Bytes).text
        wireEntryAddress = result.function.entryAddress.value
        wireEndAddressExclusive = result.function.endAddressExclusive.value
        providerIdentitySHA256 = try ReconstructionCanonicalJSON.sha256(
            of: execution.success.availability.runtimeIdentity
        )
        nativeRequestID = result.requestID
        nativeRequestSHA256 = result.requestSHA256
        nativeImageID = Self.bounded(result.image.imageID, Fact.maximumNameUTF8Bytes).text
        nativeImageUUID = result.image.uuid
        functionName = Self.bounded(result.function.name, Fact.maximumNameUTF8Bytes).text
        if let document = result.pseudocodeDocument {
            let text = Self.bounded(document.text, Fact.maximumPseudocodeUTF8Bytes)
            pseudocodeLanguage = Self.bounded(document.language, 64).text
            pseudocode = text.text
            pseudocodeWasTruncated = text.wasTruncated || document.isTruncated || !document.isComplete
        } else {
            pseudocodeLanguage = nil
            pseudocode = nil
            pseudocodeWasTruncated = false
        }
        callTargets = Array(result.calls.prefix(Fact.maximumListedNames).map { call in
            Self.bounded(call.targetSymbol
                ?? call.targetAddress.map { "0x" + String($0.value, radix: 16) }
                ?? "indirect", Fact.maximumNameUTF8Bytes).text
        })
        variableNames = Array(result.variables.prefix(Fact.maximumListedNames).map {
            Self.bounded($0.name, Fact.maximumNameUTF8Bytes).text
        })
        blockCount = result.blocks.count
        callCount = result.calls.count
        variableCount = result.variables.count
        warningCodes = Array(result.warnings.prefix(Fact.maximumListedNames).map {
            Self.bounded($0.code, Fact.maximumNameUTF8Bytes).text
        })
    }

    static func bounded(_ source: String, _ maximumBytes: Int) -> (text: String, wasTruncated: Bool) {
        var text = ""
        var used = 0
        var truncated = false
        for scalar in source.unicodeScalars where scalar.value != 0 {
            let bytes = String(scalar).utf8.count
            guard used + bytes <= maximumBytes else { truncated = true; break }
            text.unicodeScalars.append(scalar)
            used += bytes
        }
        return (text, truncated || source.unicodeScalars.contains { $0.value == 0 })
    }
}

/// Process-local, bounded holder of admitted native results. It never writes a database or
/// package; retiring a workspace or job drops its publications. Every publication receives a
/// strictly increasing generation so an older publication can never shadow a newer one.
actor ReconstructionTransientNativePublicationRegistry {
    static let shared = ReconstructionTransientNativePublicationRegistry()
    static let maximumPublicationsPerJob = 32

    private struct Key: Hashable { let workspaceID: UUID; let jobID: UUID }
    private var latestGeneration: UInt64 = 0
    private var publicationsByJob: [Key: [ReconstructionTransientNativePublication]] = [:]

    init() {}

    /// Records one completed native batch result for its exact task. Validation of the result
    /// against the current authority cut happens at every projection, never here.
    @discardableResult
    func publish(
        workspaceID: UUID,
        task: ReconstructionTaskRecord,
        success: ReconstructionNativeTaskSuccess
    ) throws -> ReconstructionTransientNativePublication {
        guard ReconstructionTransientNativeProjector.nativeTaskKinds.contains(task.identity.kind),
              case .function(let subject)? = task.identity.subject,
              success.taskID == task.identity.taskID,
              latestGeneration < .max else {
            throw ReconstructionTransientAnalysisError.invalidTransientAnalysis
        }
        latestGeneration += 1
        let publication = try ReconstructionTransientNativePublication(
            workspaceID: workspaceID, jobID: task.identity.jobID, taskID: task.identity.taskID,
            taskKind: task.identity.kind, subject: subject,
            checkpointRevision: success.checkpointRevision,
            corpusManifestSHA256: success.corpusManifestSHA256,
            generation: latestGeneration, execution: success.execution)
        let key = Key(workspaceID: workspaceID, jobID: task.identity.jobID)
        var publications = publicationsByJob[key, default: []]
        publications.append(publication)
        if publications.count > Self.maximumPublicationsPerJob {
            publications.removeFirst(publications.count - Self.maximumPublicationsPerJob)
        }
        publicationsByJob[key] = publications
        return publication
    }

    func publications(workspaceID: UUID, jobID: UUID) -> [ReconstructionTransientNativePublication] {
        publicationsByJob[Key(workspaceID: workspaceID, jobID: jobID)] ?? []
    }

    func retire(workspaceID: UUID, jobID: UUID) {
        publicationsByJob.removeValue(forKey: Key(workspaceID: workspaceID, jobID: jobID))
    }

    func retire(workspaceID: UUID) {
        publicationsByJob = publicationsByJob.filter { $0.key.workspaceID != workspaceID }
    }
}

/// Pure projection of admitted native publications onto one committed authority cut.
enum ReconstructionTransientNativeProjector {
    static let nativeTaskKinds: Set<ReconstructionTaskKind> = [.decompileNative, .compareDecompilers]
    /// Headroom kept for the request wrapper, handles, objective and readable labels.
    static let transportReserveBytes = 196_608

    /// Deterministic budget that keeps the R2 envelope (base64 context + transient section)
    /// inside the existing worker envelope ceiling. A large context leaves zero budget.
    static func budgetBytes(contextCanonicalBytes: Int) -> Int {
        let base64 = ((contextCanonicalBytes + 2) / 3) * 4
        let headroom = Phase2ReconstructionAIWorkerWireCodec.maximumEnvelopeBytes
            - base64 - transportReserveBytes
        return max(0, min(ReconstructionTransientAnalysis.maximumBudgetBytes, headroom))
    }

    static func hasCandidates(
        basis: ReconstructionProductionRoundBasis,
        publications: [ReconstructionTransientNativePublication]
    ) -> Bool {
        !publications.isEmpty || basis.tasks.contains {
            $0.identity.jobID == basis.job.jobID && $0.state == .completed
                && nativeTaskKinds.contains($0.identity.kind)
        }
    }

    static func project(
        basis: ReconstructionProductionRoundBasis,
        roundID: UUID,
        query: ReconstructionRetrievalQuery,
        evidenceIDs: [UUID],
        publications: [ReconstructionTransientNativePublication],
        budgetBytes requestedBudget: Int
    ) throws -> ReconstructionTransientAnalysis? {
        let budget = max(0, min(requestedBudget, ReconstructionTransientAnalysis.maximumBudgetBytes))
        // Only committed, in-focus native tasks of this job can be presented.
        var targets: [ReconstructionFunctionCoordinate] = []
        for task in basis.tasks where task.identity.jobID == basis.job.jobID
            && task.state == .completed && nativeTaskKinds.contains(task.identity.kind) {
            guard case .function(let function)? = task.identity.subject,
                  query.includes(subject: .function(function)),
                  !targets.contains(function) else { continue }
            targets.append(function)
        }
        var subjectDigests: [ReconstructionFunctionCoordinate: String] = [:]
        func subjectDigest(_ function: ReconstructionFunctionCoordinate) throws -> String {
            if let digest = subjectDigests[function] { return digest }
            let digest = try ReconstructionCanonicalJSON.sha256(
                of: ReconstructionSubjectCoordinate.function(function))
            subjectDigests[function] = digest
            return digest
        }
        let orderedTargets = try targets.sorted { lhs, rhs in
            if lhs.startAddress != rhs.startAddress { return lhs.startAddress < rhs.startAddress }
            if lhs.endAddressExclusive != rhs.endAddressExclusive {
                return lhs.endAddressExclusive < rhs.endAddressExclusive
            }
            return try subjectDigest(lhs) < subjectDigest(rhs)
        }

        var omissions: [ReconstructionTransientNativeOmission] = []
        var admitted: [ReconstructionFunctionCoordinate: [ReconstructionTransientNativePublication]] = [:]
        var observed: Set<ReconstructionFunctionCoordinate> = []
        let ownPublications = publications.filter {
            $0.workspaceID == basis.workspaceID && $0.jobID == basis.job.jobID
        }
        for publication in ownPublications {
            guard let disposition = classify(publication, targets: orderedTargets, basis: basis) else {
                continue
            }
            observed.insert(disposition.target)
            if let reason = disposition.reason {
                omissions.append(.init(subjectSHA256: try subjectDigest(disposition.target),
                    publicationGeneration: publication.generation, reason: reason))
            } else {
                admitted[disposition.target, default: []].append(publication)
            }
        }

        var facts: [ReconstructionTransientNativeFact] = []
        var usedBytes = 0
        let evidence = Set(evidenceIDs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for target in orderedTargets {
            try Task.checkCancellation()
            let candidates = (admitted[target] ?? []).sorted { $0.generation > $1.generation }
            guard let newest = candidates.first else {
                if !observed.contains(target) {
                    omissions.append(.init(subjectSHA256: try subjectDigest(target),
                        publicationGeneration: nil, reason: .unavailable))
                }
                continue
            }
            for older in candidates.dropFirst() {
                omissions.append(.init(subjectSHA256: try subjectDigest(target),
                    publicationGeneration: older.generation, reason: .stale))
            }
            let fact = try makeFact(newest, basis: basis, roundID: roundID)
            guard !evidence.contains(fact.factID) else {
                throw ReconstructionTransientAnalysisError.invalidTransientAnalysis
            }
            let size = try encoder.encode(fact).count
            guard facts.count < ReconstructionTransientAnalysis.maximumFacts,
                  size <= budget - usedBytes else {
                omissions.append(.init(subjectSHA256: try subjectDigest(target),
                    publicationGeneration: newest.generation, reason: .budget))
                continue
            }
            usedBytes += size
            facts.append(fact)
        }
        omissions.sort { lhs, rhs in
            if lhs.subjectSHA256 != rhs.subjectSHA256 { return lhs.subjectSHA256 < rhs.subjectSHA256 }
            if lhs.publicationGeneration != rhs.publicationGeneration {
                return (lhs.publicationGeneration ?? 0) < (rhs.publicationGeneration ?? 0)
            }
            return lhs.reason.rawValue < rhs.reason.rawValue
        }
        let boundedOmissions = Array(omissions.prefix(ReconstructionTransientAnalysis.maximumOmissions))
        guard !facts.isEmpty || !boundedOmissions.isEmpty else { return nil }
        return ReconstructionTransientAnalysis(
            schemaVersion: ReconstructionTransientAnalysis.schemaVersion,
            domain: ReconstructionTransientAnalysis.domain,
            jobID: basis.job.jobID,
            checkpointRevision: basis.checkpoint.revision,
            corpusManifestSHA256: basis.manifest.canonicalSHA256,
            evidenceFrontierSHA256: basis.evidenceCut.frontierSHA256,
            budgetBytes: budget,
            usedBytes: usedBytes,
            facts: facts,
            omissions: boundedOmissions
        )
    }

    private static func sameAddressRange(
        _ lhs: ReconstructionFunctionCoordinate,
        _ rhs: ReconstructionFunctionCoordinate
    ) -> Bool {
        lhs.startAddress == rhs.startAddress && lhs.endAddressExclusive == rhs.endAddressExclusive
    }

    /// Nil means the publication is unrelated to every in-focus target. Otherwise the reason is
    /// nil only when the publication is admissible at this exact cut.
    private static func classify(
        _ publication: ReconstructionTransientNativePublication,
        targets: [ReconstructionFunctionCoordinate],
        basis: ReconstructionProductionRoundBasis
    ) -> (target: ReconstructionFunctionCoordinate,
          reason: ReconstructionTransientNativeOmissionReason?)? {
        let subject = publication.subject
        let target: ReconstructionFunctionCoordinate
        if targets.contains(subject) {
            target = subject
        } else if let sibling = targets.first(where: { sameAddressRange($0, subject) }) {
            // Same VA, different coordinate: a sibling image, or the old bytes of this image.
            let differentImage = sibling.artifact != subject.artifact || sibling.image != subject.image
            let reason: ReconstructionTransientNativeOmissionReason
                = differentImage ? .mismatchedImage : .stale
            return (target: sibling, reason: reason)
        } else {
            return nil
        }
        guard let task = basis.tasks.first(where: { $0.identity.taskID == publication.taskID }),
              task.identity.jobID == basis.job.jobID,
              task.identity.kind == publication.taskKind,
              task.state == .completed,
              task.identity.subject == .function(subject) else {
            return (target: target, reason: ReconstructionTransientNativeOmissionReason.stale)
        }
        guard publication.checkpointRevision <= basis.checkpoint.revision,
              publication.corpusManifestSHA256 == basis.manifest.canonicalSHA256 else {
            return (target: target, reason: ReconstructionTransientNativeOmissionReason.stale)
        }
        guard let expectedFunctionID = ReconstructionReboundFunctionAuthority
                .expectedFunctionID(for: subject),
              publication.executionImageSlot == subject.image.imageSlot,
              publication.executionFunctionID == expectedFunctionID,
              publication.wireFunctionID == expectedFunctionID.uuidString.lowercased(),
              publication.wireEntryAddress == subject.startAddress,
              publication.wireEndAddressExclusive == subject.endAddressExclusive else {
            return (target: target,
                    reason: ReconstructionTransientNativeOmissionReason.mismatchedImage)
        }
        // Native output over different bytes than the committed coordinate is stale.
        guard publication.executionAnalysisInputFingerprintSHA256
                == subject.analysisFingerprintSHA256,
              basis.freshnessAuthority.currentArtifacts.contains(subject.artifact),
              let image = try? ReconstructionImageCoordinate(artifact: subject.artifact,
                  image: subject.image,
                  analysisFingerprintSHA256: subject.analysisFingerprintSHA256),
              basis.freshnessAuthority.currentImages.contains(image) else {
            return (target: target, reason: ReconstructionTransientNativeOmissionReason.stale)
        }
        return (target: target, reason: nil)
    }

    private static func makeFact(
        _ publication: ReconstructionTransientNativePublication,
        basis: ReconstructionProductionRoundBasis,
        roundID: UUID
    ) throws -> ReconstructionTransientNativeFact {
        ReconstructionTransientNativeFact(
            factID: factID(publication, basis: basis, roundID: roundID),
            subject: publication.subject,
            sourceTaskID: publication.taskID,
            providerIdentitySHA256: publication.providerIdentitySHA256,
            nativeRequestID: publication.nativeRequestID,
            nativeRequestSHA256: publication.nativeRequestSHA256,
            analysisInputFingerprintSHA256: publication.executionAnalysisInputFingerprintSHA256,
            nativeImageID: publication.nativeImageID,
            nativeImageUUID: publication.nativeImageUUID,
            publicationGeneration: publication.generation,
            functionName: publication.functionName,
            pseudocodeLanguage: publication.pseudocodeLanguage,
            pseudocode: publication.pseudocode,
            pseudocodeWasTruncated: publication.pseudocodeWasTruncated,
            callTargets: publication.callTargets,
            variableNames: publication.variableNames,
            blockCount: publication.blockCount,
            callCount: publication.callCount,
            variableCount: publication.variableCount,
            warningCodes: publication.warningCodes
        )
    }

    /// Round-scoped handle: a later round re-derives (or omits) the fact under a new ID, so a
    /// transient ID can never be carried forward as a durable citation.
    private static func factID(
        _ publication: ReconstructionTransientNativePublication,
        basis: ReconstructionProductionRoundBasis,
        roundID: UUID
    ) -> UUID {
        var preimage = Data("MacScope.ReconstructionTransientNativeFact.v1".utf8)
        for component in [
            basis.job.jobID.uuidString.lowercased(), String(basis.checkpoint.revision),
            roundID.uuidString.lowercased(), publication.taskID.uuidString.lowercased(),
            String(publication.generation), publication.nativeRequestSHA256,
            publication.providerIdentitySHA256,
        ] {
            preimage.append(0)
            preimage.append(contentsOf: component.utf8)
        }
        var bytes = Array(SHA256.hash(data: preimage).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
