import CryptoKit
import Foundation

struct ReconstructionRelationDiscoveryOccurrence: Sendable {
    let artifact: ReconstructionArtifactOccurrenceRecord
    let selectedRootOccurrenceID: ReconstructionArtifactOccurrenceID
    let relativePath: String
    let verifiedLocators: [String]

    init(
        artifact: ReconstructionArtifactOccurrenceRecord,
        selectedRootOccurrenceID: ReconstructionArtifactOccurrenceID,
        relativePath: String,
        verifiedLocators: [String]
    ) {
        self.artifact = artifact
        self.selectedRootOccurrenceID = selectedRootOccurrenceID
        self.relativePath = relativePath
        self.verifiedLocators = verifiedLocators
    }
}

struct ReconstructionContainerMembershipEvidence: Sendable {
    let containerOccurrenceID: ReconstructionArtifactOccurrenceID
    let childOccurrenceID: ReconstructionArtifactOccurrenceID
    let isVerifiedManifestEntry: Bool

    init(
        containerOccurrenceID: ReconstructionArtifactOccurrenceID,
        childOccurrenceID: ReconstructionArtifactOccurrenceID,
        isVerifiedManifestEntry: Bool
    ) {
        self.containerOccurrenceID = containerOccurrenceID
        self.childOccurrenceID = childOccurrenceID
        self.isVerifiedManifestEntry = isVerifiedManifestEntry
    }
}

struct ReconstructionSymbolicLinkEvidence: Sendable {
    let sourceOccurrenceID: ReconstructionArtifactOccurrenceID
    let selectedRootOccurrenceID: ReconstructionArtifactOccurrenceID
    let sourceRelativePath: String
    let targetText: String
    let isVerifiedManifestEntry: Bool

    init(
        sourceOccurrenceID: ReconstructionArtifactOccurrenceID,
        selectedRootOccurrenceID: ReconstructionArtifactOccurrenceID,
        sourceRelativePath: String,
        targetText: String,
        isVerifiedManifestEntry: Bool
    ) {
        self.sourceOccurrenceID = sourceOccurrenceID
        self.selectedRootOccurrenceID = selectedRootOccurrenceID
        self.sourceRelativePath = sourceRelativePath
        self.targetText = targetText
        self.isVerifiedManifestEntry = isVerifiedManifestEntry
    }
}

struct ReconstructionLoadedBinaryRelationEvidence: Sendable {
    let sourceOccurrenceID: ReconstructionArtifactOccurrenceID
    let loadedBinary: LoadedBinary

    init(
        sourceOccurrenceID: ReconstructionArtifactOccurrenceID,
        loadedBinary: LoadedBinary
    ) {
        self.sourceOccurrenceID = sourceOccurrenceID
        self.loadedBinary = loadedBinary
    }
}

struct ReconstructionRelationDiscoveryInput: Sendable {
    let occurrences: [ReconstructionRelationDiscoveryOccurrence]
    let containerMemberships: [ReconstructionContainerMembershipEvidence]
    let symbolicLinks: [ReconstructionSymbolicLinkEvidence]
    let loadedBinaries: [ReconstructionLoadedBinaryRelationEvidence]

    init(
        occurrences: [ReconstructionRelationDiscoveryOccurrence],
        containerMemberships: [ReconstructionContainerMembershipEvidence],
        symbolicLinks: [ReconstructionSymbolicLinkEvidence],
        loadedBinaries: [ReconstructionLoadedBinaryRelationEvidence]
    ) {
        self.occurrences = occurrences
        self.containerMemberships = containerMemberships
        self.symbolicLinks = symbolicLinks
        self.loadedBinaries = loadedBinaries
    }
}

enum ReconstructionRelationDiscoveryCheckpoint: Hashable, Sendable {
    case entry
    case occurrenceIndex
    case relativePathIndex
    case verifiedLocatorIndex
    case containerMembership
    case symbolicLink
    case loadedBinary
    case dependentDylib
    case relationMaterialization
}

/// Derives only evidence-grounded relationships between already acquired corpus occurrences.
///
/// This service performs no I/O and has no authority to import a dependency. Paths are treated as
/// inert lexical evidence: a targeted relation is emitted only when one normalized locator resolves
/// to exactly one already supplied occurrence. Missing or ambiguous dependency-command locators
/// remain unresolved; malformed or escaping evidence is ignored.
struct ReconstructionRelationDiscoverer: Sendable {
    struct TestHooks: Sendable {
        let didPollCancellation: (@Sendable (ReconstructionRelationDiscoveryCheckpoint) -> Void)?
        let didPerformDependencyLocatorLookup: (@Sendable (String) -> Void)?

        init(
            didPollCancellation: (
                @Sendable (ReconstructionRelationDiscoveryCheckpoint) -> Void
            )? = nil,
            didPerformDependencyLocatorLookup: (@Sendable (String) -> Void)? = nil
        ) {
            self.didPollCancellation = didPollCancellation
            self.didPerformDependencyLocatorLookup = didPerformDependencyLocatorLookup
        }
    }

    private struct IndexedOccurrence: Sendable {
        let evidence: ReconstructionRelationDiscoveryOccurrence
        let normalizedRelativePath: String
    }

    private struct RootRelativePath: Hashable, Sendable {
        let rootID: ReconstructionArtifactOccurrenceID
        let path: String
    }

    /// Retains only the cardinality needed to distinguish a unique target from an ambiguous one.
    /// Two representatives are sufficient even when the source occurrence must be excluded: three
    /// or more distinct candidates remain ambiguous after excluding at most one source.
    private struct CandidateCardinality: Sendable {
        private var first: ReconstructionArtifactOccurrenceID?
        private var second: ReconstructionArtifactOccurrenceID?
        private var hasAdditionalCandidates = false

        mutating func insert(_ candidate: ReconstructionArtifactOccurrenceID) {
            guard candidate != first, candidate != second else { return }
            if first == nil {
                first = candidate
            } else if second == nil {
                second = candidate
            } else {
                hasAdditionalCandidates = true
            }
        }

        func uniqueCandidate(
            excluding excluded: ReconstructionArtifactOccurrenceID
        ) -> ReconstructionArtifactOccurrenceID? {
            guard !hasAdditionalCandidates else { return nil }
            switch (first, second) {
            case (nil, _):
                return nil
            case (let candidate?, nil):
                return candidate == excluded ? nil : candidate
            case (let first?, let second?):
                if first == excluded { return second }
                if second == excluded { return first }
                return nil
            }
        }
    }

    private struct RelationKey: Hashable, Encodable {
        let kind: ReconstructionArtifactRelationKind
        let sourceOccurrenceID: ReconstructionArtifactOccurrenceID
        let targetOccurrenceID: ReconstructionArtifactOccurrenceID?
        let unresolvedLocator: String?
        let evidenceSource: ReconstructionRelationEvidenceSource
    }

    /// Mirrors every persisted relation field except `canonicalSHA256`. Optional fields retain the
    /// normal canonical-JSON omission behavior used by the reconstruction model layer.
    private struct CanonicalRelationBody: Encodable {
        let relationID: UUID
        let kind: ReconstructionArtifactRelationKind
        let sourceOccurrenceID: ReconstructionArtifactOccurrenceID
        let targetOccurrenceID: ReconstructionArtifactOccurrenceID?
        let unresolvedLocator: String?
        let evidenceSource: ReconstructionRelationEvidenceSource

        init(_ relation: ReconstructionArtifactRelationRecord) {
            relationID = relation.relationID
            kind = relation.kind
            sourceOccurrenceID = relation.sourceOccurrenceID
            targetOccurrenceID = relation.targetOccurrenceID
            unresolvedLocator = relation.unresolvedLocator
            evidenceSource = relation.evidenceSource
        }
    }

    private static let containerKinds: Set<ReconstructionArtifactKind> = [
        .applicationBundle,
        .frameworkBundle,
        .staticLibrary,
        .archive,
        .directory,
    ]

    private static let loadedBinarySourceKinds: Set<ReconstructionArtifactKind> = [
        .machOImage,
        .applicationBundle,
        .frameworkBundle,
        .dynamicLibrary,
        .objectFile,
    ]

    private static let dependencyTargetKinds: Set<ReconstructionArtifactKind> = [
        .dynamicLibrary,
    ]

    private let testHooks: TestHooks

    init(testHooks: TestHooks = TestHooks()) {
        self.testHooks = testHooks
    }

    func discover(
        _ input: ReconstructionRelationDiscoveryInput,
        cancellation: ReconstructionCancellation = ReconstructionCancellation()
    ) throws -> [ReconstructionArtifactRelationRecord] {
        try Self.poll(.entry, cancellation: cancellation, testHooks: testHooks)
        let occurrenceIndex = try Self.indexOccurrences(
            input.occurrences,
            cancellation: cancellation,
            testHooks: testHooks
        )
        let relativePathIndex = try Self.indexRelativePaths(
            occurrenceIndex,
            cancellation: cancellation,
            testHooks: testHooks
        )
        let locatorIndex = try Self.indexVerifiedLocators(
            occurrenceIndex,
            cancellation: cancellation,
            testHooks: testHooks
        )
        var relationKeys = Set<RelationKey>()

        try Self.discoverContainerMemberships(
            input.containerMemberships,
            occurrences: occurrenceIndex,
            cancellation: cancellation,
            testHooks: testHooks,
            into: &relationKeys
        )
        try Self.discoverSymbolicLinks(
            input.symbolicLinks,
            occurrences: occurrenceIndex,
            relativePaths: relativePathIndex,
            cancellation: cancellation,
            testHooks: testHooks,
            into: &relationKeys
        )
        try Self.discoverLoadedDependencies(
            input.loadedBinaries,
            occurrences: occurrenceIndex,
            verifiedLocators: locatorIndex,
            cancellation: cancellation,
            testHooks: testHooks,
            into: &relationKeys
        )

        try Self.poll(
            .relationMaterialization,
            cancellation: cancellation,
            testHooks: testHooks
        )
        let orderedKeys = relationKeys.sorted(by: Self.relationKeyPrecedes)
        var seenRelationIDs = Set<UUID>()
        var relations: [ReconstructionArtifactRelationRecord] = []
        relations.reserveCapacity(orderedKeys.count)
        for key in orderedKeys {
            try Self.poll(
                .relationMaterialization,
                cancellation: cancellation,
                testHooks: testHooks
            )
            let relationID = try Self.deterministicRelationID(for: key)
            guard seenRelationIDs.insert(relationID).inserted else {
                throw ReconstructionValidationError.duplicateValue(
                    field: "discovered relation IDs"
                )
            }
            let provisional = try ReconstructionArtifactRelationRecord(
                relationID: relationID,
                kind: key.kind,
                sourceOccurrenceID: key.sourceOccurrenceID,
                targetOccurrenceID: key.targetOccurrenceID,
                unresolvedLocator: key.unresolvedLocator,
                evidenceSource: key.evidenceSource,
                canonicalSHA256: String(repeating: "0", count: 64)
            )
            relations.append(try ReconstructionArtifactRelationRecord(
                relationID: relationID,
                kind: key.kind,
                sourceOccurrenceID: key.sourceOccurrenceID,
                targetOccurrenceID: key.targetOccurrenceID,
                unresolvedLocator: key.unresolvedLocator,
                evidenceSource: key.evidenceSource,
                canonicalSHA256: canonicalDigest(for: provisional)
            ))
        }
        try cancellation.check()
        return relations
    }

    func canonicalDigest(for relation: ReconstructionArtifactRelationRecord) throws -> String {
        try ReconstructionCanonicalJSON.sha256(of: CanonicalRelationBody(relation))
    }

    private static func indexOccurrences(
        _ occurrences: [ReconstructionRelationDiscoveryOccurrence],
        cancellation: ReconstructionCancellation,
        testHooks: TestHooks
    ) throws -> [ReconstructionArtifactOccurrenceID: IndexedOccurrence] {
        var buckets: [ReconstructionArtifactOccurrenceID: [IndexedOccurrence]] = [:]
        for occurrence in occurrences {
            try poll(
                .occurrenceIndex,
                cancellation: cancellation,
                testHooks: testHooks
            )
            guard let relativePath = normalizeRelativePath(
                occurrence.relativePath,
                allowRoot: true
            ) else {
                continue
            }
            buckets[occurrence.artifact.occurrenceID, default: []].append(
                IndexedOccurrence(
                    evidence: occurrence,
                    normalizedRelativePath: relativePath
                )
            )
        }
        var result: [ReconstructionArtifactOccurrenceID: IndexedOccurrence] = [:]
        for (occurrenceID, bucket) in buckets {
            try poll(
                .occurrenceIndex,
                cancellation: cancellation,
                testHooks: testHooks
            )
            if bucket.count == 1 { result[occurrenceID] = bucket[0] }
        }
        return result
    }

    private static func indexRelativePaths(
        _ occurrences: [ReconstructionArtifactOccurrenceID: IndexedOccurrence],
        cancellation: ReconstructionCancellation,
        testHooks: TestHooks
    ) throws -> [RootRelativePath: CandidateCardinality] {
        var result: [RootRelativePath: CandidateCardinality] = [:]
        for (occurrenceID, occurrence) in occurrences {
            try poll(
                .relativePathIndex,
                cancellation: cancellation,
                testHooks: testHooks
            )
            let key = RootRelativePath(
                rootID: occurrence.evidence.selectedRootOccurrenceID,
                path: occurrence.normalizedRelativePath
            )
            result[key, default: CandidateCardinality()].insert(occurrenceID)
        }
        return result
    }

    private static func indexVerifiedLocators(
        _ occurrences: [ReconstructionArtifactOccurrenceID: IndexedOccurrence],
        cancellation: ReconstructionCancellation,
        testHooks: TestHooks
    ) throws -> [String: CandidateCardinality] {
        var result: [String: CandidateCardinality] = [:]
        for (occurrenceID, occurrence) in occurrences {
            try poll(
                .verifiedLocatorIndex,
                cancellation: cancellation,
                testHooks: testHooks
            )
            guard dependencyTargetKinds.contains(occurrence.evidence.artifact.kind) else {
                continue
            }
            for locator in occurrence.evidence.verifiedLocators {
                try poll(
                    .verifiedLocatorIndex,
                    cancellation: cancellation,
                    testHooks: testHooks
                )
                guard let normalized = normalizeDependencyLocator(locator) else { continue }
                result[normalized, default: CandidateCardinality()].insert(occurrenceID)
            }
        }
        return result
    }

    private static func discoverContainerMemberships(
        _ evidenceRecords: [ReconstructionContainerMembershipEvidence],
        occurrences: [ReconstructionArtifactOccurrenceID: IndexedOccurrence],
        cancellation: ReconstructionCancellation,
        testHooks: TestHooks,
        into relations: inout Set<RelationKey>
    ) throws {
        for evidence in evidenceRecords {
            try poll(
                .containerMembership,
                cancellation: cancellation,
                testHooks: testHooks
            )
            guard evidence.isVerifiedManifestEntry,
                  evidence.containerOccurrenceID != evidence.childOccurrenceID,
                  let container = occurrences[evidence.containerOccurrenceID],
                  let child = occurrences[evidence.childOccurrenceID],
                  containerKinds.contains(container.evidence.artifact.kind),
                  container.evidence.selectedRootOccurrenceID
                    == child.evidence.selectedRootOccurrenceID else {
                continue
            }
            relations.insert(RelationKey(
                kind: .contains,
                sourceOccurrenceID: evidence.containerOccurrenceID,
                targetOccurrenceID: evidence.childOccurrenceID,
                unresolvedLocator: nil,
                evidenceSource: .containerManifest
            ))
        }
    }

    private static func discoverSymbolicLinks(
        _ evidenceRecords: [ReconstructionSymbolicLinkEvidence],
        occurrences: [ReconstructionArtifactOccurrenceID: IndexedOccurrence],
        relativePaths: [RootRelativePath: CandidateCardinality],
        cancellation: ReconstructionCancellation,
        testHooks: TestHooks,
        into relations: inout Set<RelationKey>
    ) throws {
        for evidence in evidenceRecords {
            try poll(
                .symbolicLink,
                cancellation: cancellation,
                testHooks: testHooks
            )
            guard evidence.isVerifiedManifestEntry,
                  let source = occurrences[evidence.sourceOccurrenceID],
                  source.evidence.artifact.kind == .symbolicLink,
                  source.evidence.selectedRootOccurrenceID
                    == evidence.selectedRootOccurrenceID,
                  let assertedSourcePath = normalizeRelativePath(
                    evidence.sourceRelativePath,
                    allowRoot: false
                  ),
                  assertedSourcePath == source.normalizedRelativePath,
                  let targetPath = resolveInternalSymbolicLinkTarget(
                    evidence.targetText,
                    sourceRelativePath: assertedSourcePath
                  ) else {
                continue
            }

            let targetKey = RootRelativePath(
                rootID: evidence.selectedRootOccurrenceID,
                path: targetPath
            )
            if let targetOccurrenceID = relativePaths[targetKey]?.uniqueCandidate(
                excluding: evidence.sourceOccurrenceID
            ) {
                relations.insert(RelationKey(
                    kind: .symbolicLinkTarget,
                    sourceOccurrenceID: evidence.sourceOccurrenceID,
                    targetOccurrenceID: targetOccurrenceID,
                    unresolvedLocator: nil,
                    evidenceSource: .containerManifest
                ))
            } else {
                relations.insert(RelationKey(
                    kind: .unresolvedDependency,
                    sourceOccurrenceID: evidence.sourceOccurrenceID,
                    targetOccurrenceID: nil,
                    unresolvedLocator: targetPath,
                    evidenceSource: .containerManifest
                ))
            }
        }
    }

    private static func discoverLoadedDependencies(
        _ evidenceRecords: [ReconstructionLoadedBinaryRelationEvidence],
        occurrences: [ReconstructionArtifactOccurrenceID: IndexedOccurrence],
        verifiedLocators: [String: CandidateCardinality],
        cancellation: ReconstructionCancellation,
        testHooks: TestHooks,
        into relations: inout Set<RelationKey>
    ) throws {
        for evidence in evidenceRecords {
            try poll(
                .loadedBinary,
                cancellation: cancellation,
                testHooks: testHooks
            )
            guard let source = occurrences[evidence.sourceOccurrenceID],
                  loadedBinarySourceKinds.contains(source.evidence.artifact.kind),
                  let loadedContentIdentity = contentIdentity(
                      for: evidence.loadedBinary.bytes
                  ),
                  loadedContentIdentity == source.evidence.artifact.contentIdentity,
                  let machOMetadata = evidence.loadedBinary.machOMetadata else {
                continue
            }
            try poll(
                .loadedBinary,
                cancellation: cancellation,
                testHooks: testHooks
            )
            var seenLocators = Set<String>()
            seenLocators.reserveCapacity(machOMetadata.dependentDylibs.count)
            var normalizedLocators: [String] = []
            normalizedLocators.reserveCapacity(machOMetadata.dependentDylibs.count)
            for dependency in machOMetadata.dependentDylibs {
                try poll(
                    .dependentDylib,
                    cancellation: cancellation,
                    testHooks: testHooks
                )
                guard let locator = normalizeDependencyLocator(dependency.path) else { continue }
                if seenLocators.insert(locator).inserted {
                    normalizedLocators.append(locator)
                }
            }
            for locator in normalizedLocators {
                try poll(
                    .dependentDylib,
                    cancellation: cancellation,
                    testHooks: testHooks
                )
                let targetOccurrenceID = verifiedLocators[locator]?.uniqueCandidate(
                    excluding: evidence.sourceOccurrenceID
                )
                testHooks.didPerformDependencyLocatorLookup?(locator)
                try cancellation.check()
                if let targetOccurrenceID {
                    relations.insert(RelationKey(
                        kind: .dependsOn,
                        sourceOccurrenceID: evidence.sourceOccurrenceID,
                        targetOccurrenceID: targetOccurrenceID,
                        unresolvedLocator: nil,
                        evidenceSource: .dependencyCommand
                    ))
                } else {
                    relations.insert(RelationKey(
                        kind: .unresolvedDependency,
                        sourceOccurrenceID: evidence.sourceOccurrenceID,
                        targetOccurrenceID: nil,
                        unresolvedLocator: locator,
                        evidenceSource: .dependencyCommand
                    ))
                }
            }
        }
    }

    private static func poll(
        _ checkpoint: ReconstructionRelationDiscoveryCheckpoint,
        cancellation: ReconstructionCancellation,
        testHooks: TestHooks
    ) throws {
        try cancellation.check()
        testHooks.didPollCancellation?(checkpoint)
        try cancellation.check()
    }

    private static func contentIdentity(for bytes: Data) -> ReconstructionContentIdentity? {
        try? ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            byteCount: UInt64(bytes.count)
        )
    }

    private static func relationKeyPrecedes(_ lhs: RelationKey, _ rhs: RelationKey) -> Bool {
        let lhsSource = lhs.sourceOccurrenceID.rawValue.uuidString
        let rhsSource = rhs.sourceOccurrenceID.rawValue.uuidString
        if lhsSource != rhsSource { return lhsSource < rhsSource }
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }

        let lhsTarget = lhs.targetOccurrenceID?.rawValue.uuidString ?? ""
        let rhsTarget = rhs.targetOccurrenceID?.rawValue.uuidString ?? ""
        if lhsTarget != rhsTarget { return lhsTarget < rhsTarget }

        let lhsLocator = lhs.unresolvedLocator ?? ""
        let rhsLocator = rhs.unresolvedLocator ?? ""
        if lhsLocator != rhsLocator { return lhsLocator < rhsLocator }
        return lhs.evidenceSource.rawValue < rhs.evidenceSource.rawValue
    }

    private static func deterministicRelationID(for key: RelationKey) throws -> UUID {
        let digest = try ReconstructionCanonicalJSON.sha256(of: key)
        let characters = Array(digest.utf8)
        guard characters.count == 64 else {
            throw ReconstructionValidationError.invalidSHA256(
                field: "relation identity digest"
            )
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        for index in stride(from: 0, to: 32, by: 2) {
            guard let high = hexadecimalNibble(characters[index]),
                  let low = hexadecimalNibble(characters[index + 1]) else {
                throw ReconstructionValidationError.invalidSHA256(
                    field: "relation identity digest"
                )
            }
            bytes.append((high << 4) | low)
        }
        // RFC 9562 version 8 identifies this as an application-defined, name-derived UUID while
        // retaining the first 122 deterministic digest bits.
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func hexadecimalNibble(_ character: UInt8) -> UInt8? {
        switch character {
        case 48 ... 57:
            character - 48
        case 97 ... 102:
            character - 87
        default:
            nil
        }
    }

    private static func normalizeRelativePath(
        _ rawValue: String,
        allowRoot: Bool
    ) -> String? {
        guard !rawValue.isEmpty,
              !rawValue.hasPrefix("/"),
              !containsControlCharacter(rawValue),
              let components = normalizePathComponents(
                rawValue.split(separator: "/", omittingEmptySubsequences: false).map(String.init),
                initial: []
              ) else {
            return nil
        }
        guard !components.isEmpty else { return allowRoot ? "." : nil }
        return components.joined(separator: "/").precomposedStringWithCanonicalMapping
    }

    private static func resolveInternalSymbolicLinkTarget(
        _ targetText: String,
        sourceRelativePath: String
    ) -> String? {
        guard !targetText.isEmpty,
              !targetText.hasPrefix("/"),
              !containsControlCharacter(targetText) else {
            return nil
        }
        let sourceComponents = sourceRelativePath == "."
            ? []
            : sourceRelativePath.split(separator: "/").map(String.init)
        let parentComponents = Array(sourceComponents.dropLast())
        guard let components = normalizePathComponents(
            targetText.split(separator: "/", omittingEmptySubsequences: false).map(String.init),
            initial: parentComponents
        ) else {
            return nil
        }
        return components.isEmpty
            ? "."
            : components.joined(separator: "/").precomposedStringWithCanonicalMapping
    }

    private static func normalizeDependencyLocator(_ rawValue: String) -> String? {
        guard !rawValue.isEmpty, !containsControlCharacter(rawValue) else { return nil }

        if rawValue.hasPrefix("@") {
            let rawComponents = rawValue.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard let anchor = rawComponents.first,
                  ["@executable_path", "@loader_path", "@rpath"].contains(anchor),
                  let components = normalizePathComponents(
                    Array(rawComponents.dropFirst()),
                    initial: []
                  ),
                  !components.isEmpty else {
                return nil
            }
            return ([anchor] + components)
                .joined(separator: "/")
                .precomposedStringWithCanonicalMapping
        }

        let isAbsolute = rawValue.hasPrefix("/")
        guard let components = normalizePathComponents(
            rawValue.split(separator: "/", omittingEmptySubsequences: false).map(String.init),
            initial: []
        ), !components.isEmpty else {
            return nil
        }
        let normalized = components
            .joined(separator: "/")
            .precomposedStringWithCanonicalMapping
        return isAbsolute ? "/\(normalized)" : normalized
    }

    private static func normalizePathComponents(
        _ rawComponents: [String],
        initial: [String]
    ) -> [String]? {
        var result = initial
        for rawComponent in rawComponents {
            let component = rawComponent.precomposedStringWithCanonicalMapping
            switch component {
            case "", ".":
                continue
            case "..":
                guard !result.isEmpty else { return nil }
                result.removeLast()
            default:
                guard !containsControlCharacter(component) else { return nil }
                result.append(component)
            }
        }
        return result
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7f
        }
    }
}
