import Foundation

/// A runtime document instance. This identity is intentionally not durable across document
/// closure and reopening.
struct Phase2ReadDocumentIdentity: Codable, Hashable, Sendable {
    let instanceID: UUID
}

/// A runtime workspace instance qualified by the document that owns it.
struct Phase2ReadWorkspaceIdentity: Codable, Hashable, Sendable {
    let document: Phase2ReadDocumentIdentity
    let instanceID: UUID
}

/// The exact binary owner of one workspace image slot. Reusing the slot increments
/// `ownerGeneration`; reanalysis alone does not.
struct Phase2ReadImageOwner: Codable, Hashable, Sendable {
    let slot: ImageSlot
    let binaryID: UUID
    let architecture: String
    let sliceIndex: Int?
    let ownerGeneration: UInt64
}

/// An exact image-analysis identity. Analysis results may be accepted only while both the owner
/// and the analysis revision still match.
struct Phase2ReadImageIdentity: Codable, Hashable, Sendable {
    let owner: Phase2ReadImageOwner
    let analysisRevision: UInt64
    let analysisFingerprintSHA256: String?

    init(
        owner: Phase2ReadImageOwner,
        analysisRevision: UInt64,
        analysisFingerprintSHA256: String? = nil
    ) {
        self.owner = owner
        self.analysisRevision = analysisRevision
        self.analysisFingerprintSHA256 = analysisFingerprintSHA256
    }

    var slot: ImageSlot { owner.slot }
    var binaryID: UUID { owner.binaryID }
    var architecture: String { owner.architecture }
    var sliceIndex: Int? { owner.sliceIndex }
    var ownerGeneration: UInt64 { owner.ownerGeneration }
}

/// Static address domains supported by the R1 typed-read seam. Runtime load addresses and source
/// locations remain separate, deferred identity domains and cannot be represented by this type.
enum Phase2ReadStaticAddressDomain: String, CaseIterable, Codable, Hashable, Sendable {
    case imageVirtualAddress
    case fileOffset
    case syntheticPresentation
}

/// A numeric static location qualified by its exact image-analysis owner and address domain.
struct Phase2ReadStaticLocation: Codable, Hashable, Sendable {
    let image: Phase2ReadImageIdentity
    let domain: Phase2ReadStaticAddressDomain
    let address: UInt64
}

/// The closed R1 revision vocabulary. Adding a case is a schema change.
enum Phase2ReadFacet: String, CaseIterable, Codable, Hashable, Sendable {
    case workspaceTopology
    case inputBytesAndSlice
    case loaderMetadata
    case symbols
    case functionBoundaries
    case codeDataEligibility
    case instructionDecoding
    case xrefsAndCFG
    case pseudocode
    case sourceMappings
    case userAuthoring
    case debugArtifacts
    case runtimeModules
    case runtimeStop
}

/// The owner of a facet revision. Image-scoped facets bind the binary owner but carry their
/// analysis revision separately as a dependency, allowing an analysis change to be diagnosed as
/// stale rather than as a missing dictionary key.
enum Phase2ReadFacetScope: Codable, Hashable, Sendable {
    case workspace(Phase2ReadWorkspaceIdentity)
    case image(Phase2ReadImageOwner)
}

/// A facet's revision in a current-state snapshot.
struct Phase2ReadFacetRevision: Codable, Hashable, Sendable {
    let scope: Phase2ReadFacetScope
    let facet: Phase2ReadFacet
    let revision: UInt64
    let fingerprintSHA256: String?

    init(
        scope: Phase2ReadFacetScope,
        facet: Phase2ReadFacet,
        revision: UInt64,
        fingerprintSHA256: String? = nil
    ) {
        self.scope = scope
        self.facet = facet
        self.revision = revision
        self.fingerprintSHA256 = fingerprintSHA256
    }
}

/// A captured facet revision on which an operation result depends.
struct Phase2ReadFacetDependency: Codable, Hashable, Sendable {
    let scope: Phase2ReadFacetScope
    let facet: Phase2ReadFacet
    let requiredRevision: UInt64
    let requiredFingerprintSHA256: String?

    init(
        scope: Phase2ReadFacetScope,
        facet: Phase2ReadFacet,
        requiredRevision: UInt64,
        requiredFingerprintSHA256: String? = nil
    ) {
        self.scope = scope
        self.facet = facet
        self.requiredRevision = requiredRevision
        self.requiredFingerprintSHA256 = requiredFingerprintSHA256
    }
}

/// The immutable state coordinates captured before an R1 operation executes.
struct Phase2ReadPrecondition: Codable, Hashable, Sendable {
    let workspace: Phase2ReadWorkspaceIdentity
    let workspaceRevision: UInt64
    let strictWholeWorkspace: Bool
    let image: Phase2ReadImageIdentity?
    let dependencies: [Phase2ReadFacetDependency]

    /// Compares only the explicitly captured preconditions. Undeclared current facets do not
    /// participate, and the workspace revision participates only for a strict workspace cut.
    func compared(to current: Phase2ReadCurrentState) -> Phase2ReadFreshnessComparison {
        var mismatches: [Phase2ReadFreshnessMismatch] = []

        if workspace.document != current.workspace.document {
            mismatches.append(.documentInstanceMismatch(
                expected: workspace.document,
                actual: current.workspace.document
            ))
        }

        if workspace.instanceID != current.workspace.instanceID {
            mismatches.append(.workspaceInstanceMismatch(
                expected: workspace,
                actual: current.workspace
            ))
        }

        if strictWholeWorkspace, workspaceRevision != current.workspaceRevision {
            mismatches.append(.strictWorkspaceRevisionMismatch(
                expected: workspaceRevision,
                actual: current.workspaceRevision
            ))
        }

        compareImage(to: current.image, collecting: &mismatches)
        compareFacets(to: current.facetRevisions, collecting: &mismatches)

        return Phase2ReadFreshnessComparison(mismatches: mismatches)
    }

    private func compareImage(
        to currentImage: Phase2ReadImageIdentity?,
        collecting mismatches: inout [Phase2ReadFreshnessMismatch]
    ) {
        guard let image else { return }

        guard let currentImage else {
            mismatches.append(.imageRemoved(expected: image))
            return
        }

        if image.slot != currentImage.slot {
            mismatches.append(.imageSlotMismatch(expected: image.slot, actual: currentImage.slot))
        }
        if image.binaryID != currentImage.binaryID {
            mismatches.append(.imageBinaryMismatch(
                expected: image.binaryID,
                actual: currentImage.binaryID
            ))
        }
        if image.architecture != currentImage.architecture {
            mismatches.append(.imageArchitectureMismatch(
                expected: image.architecture,
                actual: currentImage.architecture
            ))
        }
        if image.sliceIndex != currentImage.sliceIndex {
            mismatches.append(.imageSliceMismatch(
                expected: image.sliceIndex,
                actual: currentImage.sliceIndex
            ))
        }
        if image.ownerGeneration != currentImage.ownerGeneration {
            mismatches.append(.imageOwnerGenerationMismatch(
                expected: image.ownerGeneration,
                actual: currentImage.ownerGeneration
            ))
        }
        guard shouldCompareWholeImageAnalysisIdentity else { return }
        if image.analysisRevision != currentImage.analysisRevision {
            mismatches.append(.imageAnalysisRevisionMismatch(
                expected: image.analysisRevision,
                actual: currentImage.analysisRevision
            ))
        }
        if image.analysisFingerprintSHA256 != currentImage.analysisFingerprintSHA256 {
            mismatches.append(.imageAnalysisFingerprintMismatch(
                expected: image.analysisFingerprintSHA256,
                actual: currentImage.analysisFingerprintSHA256
            ))
        }
    }

    private func compareFacets(
        to currentRevisions: [Phase2ReadFacetRevision],
        collecting mismatches: inout [Phase2ReadFreshnessMismatch]
    ) {
        let dependenciesByKey = Dictionary(grouping: dependencies, by: FacetKey.init)
        let currentByKey = Dictionary(grouping: currentRevisions, by: FacetKey.init)

        for key in dependenciesByKey.keys.sorted() {
            guard let matchingDependencies = dependenciesByKey[key] else { continue }

            if matchingDependencies.count != 1 {
                mismatches.append(.duplicateDependencies(
                    scope: key.scope,
                    facet: key.facet,
                    revisions: matchingDependencies.map(\.requiredRevision).sorted()
                ))
                continue
            }

            let dependency = matchingDependencies[0]
            guard dependencyScopeIsValid(dependency.scope) else {
                mismatches.append(.dependencyScopeMismatch(dependency: dependency))
                continue
            }

            guard let matchingCurrent = currentByKey[key], !matchingCurrent.isEmpty else {
                mismatches.append(.missingFacetRevision(dependency: dependency))
                continue
            }

            guard matchingCurrent.count == 1 else {
                mismatches.append(.duplicateCurrentFacetRevisions(
                    scope: key.scope,
                    facet: key.facet,
                    revisions: matchingCurrent.map(\.revision).sorted()
                ))
                continue
            }

            let actualRevision = matchingCurrent[0].revision
            let actualFingerprint = matchingCurrent[0].fingerprintSHA256
            if let expectedFingerprint = dependency.requiredFingerprintSHA256 {
                if expectedFingerprint != actualFingerprint {
                    mismatches.append(.facetFingerprintMismatch(
                        dependency: dependency,
                        actual: actualFingerprint
                    ))
                }
            } else if dependency.requiredRevision != actualRevision {
                mismatches.append(.facetRevisionMismatch(
                    dependency: dependency,
                    actual: actualRevision
                ))
            }
        }
    }

    private func dependencyScopeIsValid(_ scope: Phase2ReadFacetScope) -> Bool {
        switch scope {
        case let .workspace(dependencyWorkspace):
            dependencyWorkspace == workspace
        case let .image(dependencyOwner):
            image?.owner == dependencyOwner
        }
    }

    /// App-minted preconditions can now bind analysis freshness to each declared image facet.
    /// Older/manual preconditions without facet fingerprints keep the conservative whole-image
    /// revision/fingerprint check so they cannot silently pass across an unqualified analysis edit.
    private var shouldCompareWholeImageAnalysisIdentity: Bool {
        !dependencies.contains { dependency in
            guard dependency.requiredFingerprintSHA256 != nil else { return false }
            if case .image = dependency.scope { return true }
            return false
        }
    }
}

/// The current coordinates against which an operation result is revalidated.
struct Phase2ReadCurrentState: Codable, Hashable, Sendable {
    let workspace: Phase2ReadWorkspaceIdentity
    let workspaceRevision: UInt64
    /// The current exact owner of the requested slot, or `nil` if that slot is unresolved.
    let image: Phase2ReadImageIdentity?
    let facetRevisions: [Phase2ReadFacetRevision]
}

/// Closed, inspectable causes for precondition rejection.
enum Phase2ReadFreshnessMismatch: Codable, Hashable, Sendable {
    case documentInstanceMismatch(
        expected: Phase2ReadDocumentIdentity,
        actual: Phase2ReadDocumentIdentity
    )
    case workspaceInstanceMismatch(
        expected: Phase2ReadWorkspaceIdentity,
        actual: Phase2ReadWorkspaceIdentity
    )
    case strictWorkspaceRevisionMismatch(expected: UInt64, actual: UInt64)
    case imageRemoved(expected: Phase2ReadImageIdentity)
    case imageSlotMismatch(expected: ImageSlot, actual: ImageSlot)
    case imageBinaryMismatch(expected: UUID, actual: UUID)
    case imageArchitectureMismatch(expected: String, actual: String)
    case imageSliceMismatch(expected: Int?, actual: Int?)
    case imageOwnerGenerationMismatch(expected: UInt64, actual: UInt64)
    @available(*, deprecated, message: "Use facetRevisionMismatch for legacy freshness or facetFingerprintMismatch for fingerprint-qualified reads.")
    case imageAnalysisRevisionMismatch(expected: UInt64, actual: UInt64)
    @available(*, deprecated, message: "Use facetFingerprintMismatch for fingerprint-qualified reads.")
    case imageAnalysisFingerprintMismatch(expected: String?, actual: String?)
    case dependencyScopeMismatch(dependency: Phase2ReadFacetDependency)
    case duplicateDependencies(
        scope: Phase2ReadFacetScope,
        facet: Phase2ReadFacet,
        revisions: [UInt64]
    )
    case missingFacetRevision(dependency: Phase2ReadFacetDependency)
    case duplicateCurrentFacetRevisions(
        scope: Phase2ReadFacetScope,
        facet: Phase2ReadFacet,
        revisions: [UInt64]
    )
    case facetRevisionMismatch(dependency: Phase2ReadFacetDependency, actual: UInt64)
    case facetFingerprintMismatch(dependency: Phase2ReadFacetDependency, actual: String?)

    fileprivate var isOwnerMismatch: Bool {
        switch self {
        case .documentInstanceMismatch,
             .workspaceInstanceMismatch,
             .imageRemoved,
             .imageSlotMismatch,
             .imageBinaryMismatch,
             .imageArchitectureMismatch,
             .imageSliceMismatch,
             .imageOwnerGenerationMismatch,
             .dependencyScopeMismatch:
            true
        case .strictWorkspaceRevisionMismatch,
             .imageAnalysisRevisionMismatch,
             .imageAnalysisFingerprintMismatch,
             .duplicateDependencies,
             .missingFacetRevision,
             .duplicateCurrentFacetRevisions,
             .facetRevisionMismatch,
             .facetFingerprintMismatch:
            false
        }
    }

    fileprivate var isFreshnessMismatch: Bool {
        switch self {
        case .strictWorkspaceRevisionMismatch,
             .imageAnalysisRevisionMismatch,
             .imageAnalysisFingerprintMismatch,
             .duplicateDependencies,
             .missingFacetRevision,
             .duplicateCurrentFacetRevisions,
             .facetRevisionMismatch,
             .facetFingerprintMismatch:
            true
        case .documentInstanceMismatch,
             .workspaceInstanceMismatch,
             .imageRemoved,
             .imageSlotMismatch,
             .imageBinaryMismatch,
             .imageArchitectureMismatch,
             .imageSliceMismatch,
             .imageOwnerGenerationMismatch,
             .dependencyScopeMismatch:
            false
        }
    }
}

/// A side-effect-free comparison result. Mismatch ordering is deterministic and independent of
/// dependency/current-revision input ordering.
struct Phase2ReadFreshnessComparison: Codable, Hashable, Sendable {
    let mismatches: [Phase2ReadFreshnessMismatch]

    var isCurrent: Bool { mismatches.isEmpty }
    var isOwnerCurrent: Bool { !mismatches.contains(where: \.isOwnerMismatch) }
    var isStale: Bool { mismatches.contains(where: \.isFreshnessMismatch) }
}

private struct FacetKey: Hashable, Comparable {
    let scope: Phase2ReadFacetScope
    let facet: Phase2ReadFacet

    init(_ dependency: Phase2ReadFacetDependency) {
        scope = dependency.scope
        facet = dependency.facet
    }

    init(_ revision: Phase2ReadFacetRevision) {
        scope = revision.scope
        facet = revision.facet
    }

    static func < (lhs: FacetKey, rhs: FacetKey) -> Bool {
        let scopeOrder = compare(lhs.scope, rhs.scope)
        if scopeOrder != .orderedSame {
            return scopeOrder == .orderedAscending
        }
        return lhs.facet.rawValue < rhs.facet.rawValue
    }

    private static func compare(
        _ lhs: Phase2ReadFacetScope,
        _ rhs: Phase2ReadFacetScope
    ) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (.workspace(left), .workspace(right)):
            compare(
                [left.document.instanceID.uuidString, left.instanceID.uuidString],
                [right.document.instanceID.uuidString, right.instanceID.uuidString]
            )
        case (.workspace, .image):
            .orderedAscending
        case (.image, .workspace):
            .orderedDescending
        case let (.image(left), .image(right)):
            compare(
                [
                    String(left.slot.rawValue),
                    left.binaryID.uuidString,
                    left.architecture,
                    left.sliceIndex.map(String.init) ?? "nil",
                    String(left.ownerGeneration),
                ],
                [
                    String(right.slot.rawValue),
                    right.binaryID.uuidString,
                    right.architecture,
                    right.sliceIndex.map(String.init) ?? "nil",
                    String(right.ownerGeneration),
                ]
            )
        }
    }

    private static func compare(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
        for (left, right) in zip(lhs, rhs) where left != right {
            return left < right ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }
}
