import Foundation

/// Transient, monotonic runtime identities for app-owned Phase 2 reads.
///
/// The first R1 coordinator intentionally advances image analysis as one conservative revision.
/// A delayed result may therefore be rejected more often than strictly necessary, but it can
/// never become current again through numeric slot reuse.
struct Phase2ReadRevisionLedger: Sendable {
    private struct ImageRecord: Sendable {
        var identity: Phase2ReadImageIdentity
    }

    private(set) var workspace = Phase2ReadWorkspaceIdentity(
        document: .init(instanceID: UUID()),
        instanceID: UUID()
    )
    private(set) var workspaceRevision: UInt64 = 1
    private var recordsBySlot: [ImageSlot: ImageRecord] = [:]
    private var lastOwnerGenerationBySlot: [ImageSlot: UInt64] = [:]

    mutating func installInitial(snapshot: WorkspaceSnapshot) {
        recordsBySlot.removeAll(keepingCapacity: true)
        for binary in snapshot.binaries {
            installNewOwner(binary, snapshot: snapshot)
        }
    }

    mutating func noteWorkspaceMetadataChange() {
        advance(&workspaceRevision)
    }

    /// Remints the workspace identity even when a restored snapshot happens to reuse all persisted
    /// binary UUIDs and numeric slots.
    mutating func replaceWorkspace(with snapshot: WorkspaceSnapshot) {
        workspace = .init(document: workspace.document, instanceID: UUID())
        advance(&workspaceRevision)
        recordsBySlot.removeAll(keepingCapacity: true)
        for binary in snapshot.binaries {
            installNewOwner(binary, snapshot: snapshot)
        }
    }

    /// Ingests one published snapshot. Common exact owners conservatively advance their single R1
    /// analysis revision; replacement owners receive a fresh retained generation.
    mutating func ingestSnapshotTransition(
        from prior: WorkspaceSnapshot,
        to current: WorkspaceSnapshot
    ) {
        let priorOwners = Dictionary(uniqueKeysWithValues: prior.binaries.map { ($0.slot, $0) })
        let currentOwners = Dictionary(uniqueKeysWithValues: current.binaries.map { ($0.slot, $0) })
        let topologyChanged = Set(priorOwners.keys) != Set(currentOwners.keys)
            || currentOwners.contains { slot, binary in
                guard let priorBinary = priorOwners[slot] else { return true }
                return !sameOwner(priorBinary, binary)
            }

        if topologyChanged {
            advance(&workspaceRevision)
        }

        for slot in recordsBySlot.keys where currentOwners[slot] == nil {
            recordsBySlot[slot] = nil
        }

        for binary in current.binaries {
            if let existing = recordsBySlot[binary.slot], owner(existing.identity.owner, matches: binary) {
                var analysisRevision = existing.identity.analysisRevision
                advance(&analysisRevision)
                recordsBySlot[binary.slot] = ImageRecord(identity: .init(
                    owner: existing.identity.owner,
                    analysisRevision: analysisRevision,
                    analysisFingerprintSHA256: analysisFingerprintSHA256(for: binary, in: current)
                ))
            } else {
                installNewOwner(binary, snapshot: current)
            }
        }
    }

    func imageIdentity(in slot: ImageSlot, snapshot: WorkspaceSnapshot) -> Phase2ReadImageIdentity? {
        guard let binary = snapshot.binary(in: slot),
              let record = recordsBySlot[slot],
              owner(record.identity.owner, matches: binary)
        else { return nil }
        return record.identity
    }

    func currentState(
        for slot: ImageSlot?,
        snapshot: WorkspaceSnapshot
    ) -> Phase2ReadCurrentState {
        let image = slot.flatMap { imageIdentity(in: $0, snapshot: snapshot) }
        var facets = [Phase2ReadFacetRevision(
            scope: .workspace(workspace),
            facet: .workspaceTopology,
            revision: workspaceRevision
        )]
        if let image {
            facets.append(contentsOf: Self.imageFacets.map { facet in
                Phase2ReadFacetRevision(
                    scope: .image(image.owner),
                    facet: facet,
                    revision: image.analysisRevision,
                    fingerprintSHA256: analysisFacetFingerprintSHA256(
                        for: facet,
                        image: image,
                        in: snapshot
                    )
                )
            })
        }
        return Phase2ReadCurrentState(
            workspace: workspace,
            workspaceRevision: workspaceRevision,
            image: image,
            facetRevisions: facets
        )
    }

    func dependencies(
        for facets: [Phase2ReadFacet],
        image: Phase2ReadImageIdentity?,
        snapshot: WorkspaceSnapshot
    ) -> [Phase2ReadFacetDependency] {
        facets.compactMap { facet in
            if facet == .workspaceTopology {
                return Phase2ReadFacetDependency(
                    scope: .workspace(workspace),
                    facet: facet,
                    requiredRevision: workspaceRevision
                )
            }
            guard let image else { return nil }
            return Phase2ReadFacetDependency(
                scope: .image(image.owner),
                facet: facet,
                requiredRevision: image.analysisRevision,
                requiredFingerprintSHA256: analysisFacetFingerprintSHA256(
                    for: facet,
                    image: image,
                    in: snapshot
                )
            )
        }
    }

    private mutating func installNewOwner(_ binary: BinaryImage, snapshot: WorkspaceSnapshot) {
        var generation = lastOwnerGenerationBySlot[binary.slot] ?? 0
        advance(&generation)
        lastOwnerGenerationBySlot[binary.slot] = generation
        let owner = Phase2ReadImageOwner(
            slot: binary.slot,
            binaryID: binary.id,
            architecture: binary.architecture,
            sliceIndex: binary.selectedSliceIndex,
            ownerGeneration: generation
        )
        recordsBySlot[binary.slot] = ImageRecord(
            identity: .init(
                owner: owner,
                analysisRevision: 1,
                analysisFingerprintSHA256: analysisFingerprintSHA256(for: binary, in: snapshot)
            )
        )
    }

    private func analysisFingerprintSHA256(
        for binary: BinaryImage,
        in snapshot: WorkspaceSnapshot
    ) -> String? {
        snapshot.analysis(in: binary.slot)?.analysisInputFingerprint?.overallSHA256
    }

    private func analysisFacetFingerprintSHA256(
        for facet: Phase2ReadFacet,
        image: Phase2ReadImageIdentity,
        in snapshot: WorkspaceSnapshot?
    ) -> String? {
        guard let fingerprint = snapshot?
            .analysis(in: image.slot)?
            .analysisInputFingerprint
        else {
            return nil
        }
        return Self.analysisFacetFingerprintSHA256(for: facet, fingerprint: fingerprint)
    }

    private static func analysisFacetFingerprintSHA256(
        for facet: Phase2ReadFacet,
        fingerprint: AnalysisInputFingerprint
    ) -> String? {
        let kinds = analysisFingerprintKinds(for: facet)
        guard !kinds.isEmpty else { return nil }
        var facetsByKind: [AnalysisFingerprintFacetKind: AnalysisFacetFingerprint] = [:]
        for fingerprintFacet in fingerprint.facets {
            guard facetsByKind[fingerprintFacet.kind] == nil else { return nil }
            facetsByKind[fingerprintFacet.kind] = fingerprintFacet
        }
        let facetDigests = kinds.compactMap { kind -> (AnalysisFingerprintFacetKind, String)? in
            guard let digest = facetsByKind[kind]?.sha256 else { return nil }
            return (kind, digest)
        }
        guard facetDigests.count == kinds.count else { return nil }
        guard facetDigests.count != 1 else { return facetDigests[0].1 }

        var writer = AnalysisFingerprintCanonicalWriter()
        for (kind, digest) in facetDigests.sorted(by: { $0.0.rawValue < $1.0.rawValue }) {
            writer.beginRecord("phase2FacetDigest")
            writer.field("phase2Facet", facet.rawValue)
            writer.field("analysisFacet", kind.rawValue)
            writer.field("sha256", digest)
            writer.endRecord("phase2FacetDigest")
        }
        return writer.digestHex()
    }

    private static func analysisFingerprintKinds(
        for facet: Phase2ReadFacet
    ) -> [AnalysisFingerprintFacetKind] {
        switch facet {
        case .workspaceTopology:
            []
        case .inputBytesAndSlice:
            [.selectedSliceBytes]
        case .loaderMetadata:
            [.loaderSections, .relocations, .machOLoadMetadata]
        case .symbols:
            []
        case .functionBoundaries:
            [.functions]
        case .codeDataEligibility:
            [.codeDataRanges]
        case .instructionDecoding:
            [.decodedInstructions]
        case .xrefsAndCFG:
            [.controlFlow, .xrefs]
        case .pseudocode:
            [.decodedInstructions, .functions, .controlFlow]
        case .sourceMappings:
            [.debugSourceLines]
        case .userAuthoring:
            []
        case .debugArtifacts:
            [.debugSourceLines]
        case .runtimeModules, .runtimeStop:
            []
        }
    }

    private func owner(_ owner: Phase2ReadImageOwner, matches binary: BinaryImage) -> Bool {
        owner.slot == binary.slot
            && owner.binaryID == binary.id
            && owner.architecture == binary.architecture
            && owner.sliceIndex == binary.selectedSliceIndex
    }

    private func sameOwner(_ lhs: BinaryImage, _ rhs: BinaryImage) -> Bool {
        lhs.slot == rhs.slot
            && lhs.id == rhs.id
            && lhs.architecture == rhs.architecture
            && lhs.selectedSliceIndex == rhs.selectedSliceIndex
    }

    /// Exhaustion remints the enclosing runtime identity instead of wrapping to a previously valid
    /// revision. In practice this branch is unreachable, but wraparound must not revive authority.
    private func advance(_ value: inout UInt64) {
        precondition(value < .max, "Phase 2 revision space exhausted")
        value += 1
    }

    private static let imageFacets = Phase2ReadFacet.allCases.filter { $0 != .workspaceTopology }
}
