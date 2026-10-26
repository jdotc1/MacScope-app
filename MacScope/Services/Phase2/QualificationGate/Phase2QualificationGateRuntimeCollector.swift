import CryptoKit
import CFNetwork
import Darwin
import Foundation
@testable import MacScope
import Security

enum Phase2QualificationGateRuntimeCollectorError: Error, Equatable, Sendable {
    case artifactUnavailable
    case environmentUnavailable
    case providerUnavailable
    case providerMismatch
    case processAuthorityUnavailable
    case unsupportedProviderProfile
    case providerAdmissionUnavailable(Phase2ProviderAdmissionUnavailableReason)
    case preflightRejected([Phase2LiveQualificationPreflightDeficiency])
}

/// Authority returned only by the zero-input production collector. Its initializer is intentionally
/// file-private: test composition can validate closed evidence, but cannot manufacture a live
/// dispatch session from caller-supplied observations.
@MainActor
final class Phase2QualificationGateRuntimeSession {
    let runID: UUID
    let preparedQualification: Phase2PreparedLiveQualification
    let controllerAuthority: Phase2LocalAIProviderController
    let buildAuthority: Phase2QualificationGateBuildAuthority
    let profileContract: Phase2QualificationProfileContract
    let providerAdmission: Phase2ProviderAdmissionEvidence?

    private let endpoint: Phase2LocalProviderEndpoint
    private let explicitLoadedInstanceID: String
    private let artifactObservation: Phase2LiveQualificationArtifactObservation
    private let artifactSeal: Phase2QualificationGateArtifactSeal
    private let environmentSeal: Phase2QualificationGateEnvironmentSeal
    private let staticContext: Phase2QualificationGateStaticContext

    fileprivate init(
        runID: UUID,
        preparedQualification: Phase2PreparedLiveQualification,
        controllerAuthority: Phase2LocalAIProviderController,
        buildAuthority: Phase2QualificationGateBuildAuthority,
        endpoint: Phase2LocalProviderEndpoint,
        explicitLoadedInstanceID: String,
        artifactObservation: Phase2LiveQualificationArtifactObservation,
        artifactSeal: Phase2QualificationGateArtifactSeal,
        environmentSeal: Phase2QualificationGateEnvironmentSeal,
        staticContext: Phase2QualificationGateStaticContext
    ) {
        self.runID = runID
        self.preparedQualification = preparedQualification
        self.controllerAuthority = controllerAuthority
        self.buildAuthority = buildAuthority
        self.endpoint = endpoint
        self.explicitLoadedInstanceID = explicitLoadedInstanceID
        self.artifactObservation = artifactObservation
        self.artifactSeal = artifactSeal
        self.environmentSeal = environmentSeal
        self.staticContext = staticContext
        // Only the historical branch can currently create a session. Candidate collection
        // fails closed until a reviewed engine/template closure is compiled into the registry.
        profileContract = .resolve(.historicalF4C)
        providerAdmission = nil
    }

    /// Synchronous because the accepted runtime-validator seam is synchronous. The collector owns
    /// a bounded no-cache catalog probe plus local file/process seals; it never trusts a caller copy.
    func captureFreshObservation() -> Phase2LiveQualificationFreshObservation? {
        guard !profileContract.requiresProviderAdmission,
              artifactSeal.isCurrent(), environmentSeal.isCurrent(),
              let currentLease = controllerAuthority.captureReadyInferenceLease(),
              currentLease == preparedQualification.runtimeBinding.readyLease,
              let inventory = Phase2QualificationGateDirectCatalogCollector.collect(
                endpoint: endpoint
              ),
              let provider = Phase2QualificationGateProviderCollector.collect(
                endpoint: endpoint,
                providerRevision: controllerAuthority.snapshot.revision,
                inventory: inventory
              ),
              provider.identity == preparedQualification.runtimeBinding.provider,
              provider.runtimeIdentity
                == preparedQualification.runtimeBinding.providerRuntimeIdentity
        else { return nil }

        let current = controllerAuthority.snapshot
        let freshSnapshot = Phase2LocalAIProviderSnapshot(
            endpoint: endpoint,
            observation: .accepted(inventory),
            desiredSelection: current.desiredSelection,
            selection: current.selection,
            activity: current.activity,
            revision: current.revision
        )
        guard freshSnapshot.readyInferenceLease == currentLease else { return nil }
        return .init(
            snapshot: freshSnapshot,
            readyLease: currentLease,
            explicitLoadedInstanceID: explicitLoadedInstanceID,
            providerObservation: provider,
            artifactObservation: artifactObservation,
            contextObservation: staticContext.context,
            generationObservation: staticContext.generation,
            hardwareObservation: staticContext.hardwareTier,
            productionDefinitionObservation: staticContext.production.definitionIdentity,
            protocolManifestObservation: staticContext.manifest,
            readToolRegistryObservation: staticContext.manifest.readToolRegistry,
            qualificationPolicyObservation: staticContext.production.policyIdentity,
            protocolProbeCatalogObservation:
                staticContext.production.protocolProbeCatalogIdentity,
            liveCorpusObservation: staticContext.production.liveScenarioCatalog.identity,
            environmentObservation: environmentSeal.environment
        )
    }

    func validateArtifactCryptographically() -> Bool {
        Phase2QualificationGateFinalAuthorityClosure.validate(
            environmentIsCurrent: environmentSeal.isCurrent,
            artifactIsCryptographicallyCurrent: artifactSeal.isCryptographicallyCurrent
        )
    }
}

/// Closes Gate-G4 evidence only while the signed candidate/install/runner and host environment
/// remain exact on both sides of the full model-artifact rehash. Keeping the two observations
/// distinct prevents a long cryptographic pass from turning an earlier build-authority check into
/// report authority after the installed app or host state has drifted.
@MainActor
enum Phase2QualificationGateFinalAuthorityClosure {
    static func validate(
        environmentIsCurrent: () -> Bool,
        artifactIsCryptographicallyCurrent: () -> Bool
    ) -> Bool {
        guard environmentIsCurrent() else { return false }
        let artifactRemainsCurrent = artifactIsCryptographicallyCurrent()
        let environmentRemainsCurrent = environmentIsCurrent()
        return artifactRemainsCurrent && environmentRemainsCurrent
    }
}

@MainActor
enum Phase2QualificationGateRuntimeCollector {
    private static let endpointOrigin = "http://127.0.0.1:1234"
    private static let modelKey = "qwen3-coder-30b-a3b-instruct"
    private static let modelPublisher = "mlx-community"
    private static let modelDirectory =
        "mlx-community/Qwen3-Coder-30B-A3B-Instruct-8bit"
    private static let loadedInstanceID = "qwen3-coder-30b-a3b-instruct"
    private static let expectedArtifactFiles = 18
    private static let expectedArtifactBytes: UInt64 = 32_456_771_170
    private static let expectedArtifactManifest =
        "49060c25bb8c4f63ef7471796832dc9e7c12b63e553472907ae27f05c7596ace"

    static func collectCurrent(
        selector: Phase2QualificationProfileSelector = .historicalF4C
    ) async throws -> Phase2QualificationGateRuntimeSession {
        // These selectors describe retained pre-cutover evidence, not current
        // MTPLX runtime authority. Reject before touching legacy artifacts/listeners.
        switch selector {
        case .historicalF4C, .qwen38V2Q6K:
            throw Phase2QualificationGateRuntimeCollectorError.unsupportedProviderProfile
        }
    }

    static func collectInstalledCanaryCurrent(
        selector: Phase2QualificationProfileSelector = .historicalF4C
    ) async throws
        -> Phase2QualificationGateRuntimeSession
    {
        switch selector {
        case .historicalF4C, .qwen38V2Q6K:
            throw Phase2QualificationGateRuntimeCollectorError.unsupportedProviderProfile
        }
    }

    /// Read-only admission diagnostics, never a load/setter or session factory. A valid
    /// standalone signature and inventory do not stand in for the unreviewed engine closure.
    private static func rejectUnreviewedCandidate() async throws -> Never {
        let endpoint = try Phase2LocalAIProviderPreference(
            endpointOrigin: endpointOrigin,
            requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 30_000,
            desiredSelection: try .init(
                modelKey: Phase2QualificationGateCandidateModelPolicy.modelKey,
                maximumTokens: 4_096
            )
        )
        let controller = Phase2LocalAIProviderController(
            preferenceStore: InMemoryPhase2LocalAIProviderPreferenceStore(initialPreference: endpoint)
        )
        guard let selectedEndpoint = controller.snapshot.endpoint,
              let loopback = try? Phase2LoopbackEndpoint(validating: selectedEndpoint.endpointOrigin),
              let process = Phase2QualificationGateLibprocProviderDiscoverer().uniqueListenerProcess(
                endpoint: loopback, processObserver: Phase2QualificationLibprocProcessObserver()
              ) else {
            throw Phase2QualificationGateRuntimeCollectorError.providerAdmissionUnavailable(.listenerMissing)
        }
        guard process.executableIdentity.sha256 == Phase2QualificationProviderAdmissionPolicy.executableSHA256 else {
            throw Phase2QualificationGateRuntimeCollectorError.providerAdmissionUnavailable(.executableMismatch)
        }
        guard Phase2QualificationGateProviderCodeAuthority.accepts(process, selector: .qwen38V2Q6K) else {
            throw Phase2QualificationGateRuntimeCollectorError.providerAdmissionUnavailable(.signatureMismatch)
        }
        guard case .success = try await controller.refresh(),
              let inventory = controller.snapshot.inventory,
              Phase2QualificationGateCandidateModelPolicy.exactModel(inventory) != nil else {
            throw Phase2QualificationGateRuntimeCollectorError.providerAdmissionUnavailable(.loadedConfigurationUnavailable)
        }
        guard let current = Phase2QualificationGateLibprocProviderDiscoverer().uniqueListenerProcess(
            endpoint: loopback, processObserver: Phase2QualificationLibprocProcessObserver()
        ), current.hasSameIdentity(as: process),
           Phase2QualificationGateProviderCodeAuthority.accepts(current, selector: .qwen38V2Q6K) else {
            throw Phase2QualificationGateRuntimeCollectorError.providerAdmissionUnavailable(.changedDuringCapture)
        }
        throw Phase2QualificationGateRuntimeCollectorError.providerAdmissionUnavailable(.runtimeClosureUnreviewed)
    }

    private static func collectCurrent(
        installationMode: Phase2QualificationGateInstallationMode
    ) async throws -> Phase2QualificationGateRuntimeSession {
        let production = Phase2ProductionQualificationPolicy.standard
        let runID = UUID()
        let artifactURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lmstudio/models", isDirectory: true)
            .appendingPathComponent(modelDirectory, isDirectory: true)
        let manifest = try Phase2QualificationGateArtifactManifest.collect(at: artifactURL)
        guard manifest.fileCount == expectedArtifactFiles,
              manifest.totalBytes == expectedArtifactBytes,
              manifest.sha256 == expectedArtifactManifest,
              manifest.sha256 == production.modelRevision.localArtifactManifestSHA256
        else { throw Phase2QualificationGateRuntimeCollectorError.artifactUnavailable }

        let buildAuthority = switch installationMode {
        case .stagedCandidate:
            try Phase2QualificationGateBuildAuthority.collectCurrent()
        case .installedCanary:
            try Phase2QualificationGateBuildAuthority.collectInstalledCanaryCurrent()
        }
        let environmentSeal = try Phase2QualificationGateEnvironmentCollector.collectEnvironment(
            buildAuthority: buildAuthority
        )
        guard production.environmentPolicy.accepts(environmentSeal.environment) else {
            throw Phase2QualificationGateRuntimeCollectorError.environmentUnavailable
        }
        let preference = try Phase2LocalAIProviderPreference(
            endpointOrigin: endpointOrigin,
            requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 30_000,
            desiredSelection: try .init(modelKey: modelKey, maximumTokens: 4_096)
        )
        let controller = Phase2LocalAIProviderController(
            preferenceStore: InMemoryPhase2LocalAIProviderPreferenceStore(
                initialPreference: preference
            )
        )
        guard let endpoint = controller.snapshot.endpoint else {
            throw Phase2QualificationGateRuntimeCollectorError.providerUnavailable
        }
        guard case .success = try await controller.refresh() else {
            throw Phase2QualificationGateRuntimeCollectorError.providerUnavailable
        }
        let snapshot = controller.snapshot
        guard let inventory = snapshot.inventory,
              let model = exactModel(inventory),
              let loadedInstance = exactLoadedInstance(in: model)
        else { throw Phase2QualificationGateRuntimeCollectorError.providerMismatch }
        guard let readyLease = controller.captureReadyInferenceLease() else {
            throw Phase2QualificationGateRuntimeCollectorError.providerMismatch
        }

        guard let provider = Phase2QualificationGateProviderCollector.collect(
            endpoint: endpoint,
            providerRevision: controller.snapshot.revision,
            inventory: inventory
        ) else {
            throw Phase2QualificationGateRuntimeCollectorError.processAuthorityUnavailable
        }
        let backingDigest = try Phase2ModelBackingDigest.sha256(manifest.sha256)
        let artifactObservation = Phase2LiveQualificationArtifactObservation(
            source: production.modelRevision.modelSource,
            backingDigest: backingDigest,
            modelRevision: production.modelRevision.identity
        )
        let staticContext = try Phase2QualificationGateStaticContext(
            production: production,
            provider: provider.identity,
            model: model,
            loadedConfiguration: loadedInstance.configuration,
            backingDigest: backingDigest,
            environment: environmentSeal.environment
        )
        let preflight = Phase2LiveQualificationPreflight().evaluate(.init(
            standard: staticContext.definition,
            snapshot: controller.snapshot,
            readyLease: readyLease,
            explicitLoadedInstanceID: loadedInstance.id,
            providerObservation: provider,
            artifactObservation: artifactObservation,
            contextObservation: staticContext.context,
            generationObservation: staticContext.generation,
            hardwareObservation: staticContext.hardwareTier,
            protocolManifestObservation: staticContext.manifest,
            readToolRegistryObservation: staticContext.manifest.readToolRegistry,
            qualificationPolicyObservation: production.policyIdentity,
            protocolProbeCatalogObservation: production.protocolProbeCatalogIdentity,
            liveCorpusObservation: production.liveScenarioCatalog.identity,
            environmentObservation: environmentSeal.environment
        ))
        guard case .prepared(let prepared) = preflight else {
            guard case .rejected(let rejection) = preflight else {
                throw Phase2QualificationGateRuntimeCollectorError.providerMismatch
            }
            throw Phase2QualificationGateRuntimeCollectorError.preflightRejected(
                rejection.deficiencies
            )
        }
        return .init(
            runID: runID,
            preparedQualification: prepared,
            controllerAuthority: controller,
            buildAuthority: buildAuthority,
            endpoint: endpoint,
            explicitLoadedInstanceID: loadedInstance.id,
            artifactObservation: artifactObservation,
            artifactSeal: manifest.seal,
            environmentSeal: environmentSeal,
            staticContext: staticContext
        )
    }

    private static func exactModel(
        _ inventory: Phase2LocalModelInventory
    ) -> Phase2LocalModelDescriptor? {
        let matches = inventory.models.filter { model in
            guard model.key == modelKey,
                  model.publisher == modelPublisher,
                  model.type == .language,
                  model.format == .mlx,
                  model.quantization?.name == "8bit",
                  model.quantization?.bitsPerWeight == 8,
                  model.sizeBytesOnDisk == expectedArtifactBytes,
                  model.maximumContextLength == 262_144,
                  let loadedInstance = exactLoadedInstance(in: model)
            else { return false }
            return loadedInstance.configuration.effectiveContextLength == 32_768
                && loadedInstance.configuration.parallelPredictions == 1
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func exactLoadedInstance(
        in model: Phase2LocalModelDescriptor
    ) -> Phase2LocalModelLoadedInstance? {
        guard model.loadedInstances.count == 1 else { return nil }
        let identifiers = model.loadedInstances.map(\.id)
        guard Set(identifiers).count == identifiers.count else { return nil }
        let instancesByID = Dictionary(
            uniqueKeysWithValues: model.loadedInstances.map { ($0.id, $0) }
        )
        return instancesByID[loadedInstanceID]
    }
}

/// Selection evidence only; this helper cannot grant provider or runtime authority.
enum Phase2QualificationGateCandidateModelPolicy {
    static let modelKey = "qwen3.8-27b-obliterated"

    static func exactModel(_ inventory: Phase2LocalModelInventory) -> Phase2LocalModelDescriptor? {
        let matches = inventory.models.filter { model in
            model.key == modelKey && model.publisher == "OBLITERATUS"
                && model.type == .language && model.format == .gguf
                && model.quantization?.name == "Q6_K"
                && model.sizeBytesOnDisk == 22_431_004_152
                && model.maximumContextLength == 262_144
                && exactLoadedInstance(in: model) != nil
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func exactLoadedInstance(in model: Phase2LocalModelDescriptor) -> Phase2LocalModelLoadedInstance? {
        guard model.loadedInstances.count == 1, let instance = model.loadedInstances.first,
              !instance.id.isEmpty,
              instance.id == instance.id.trimmingCharacters(in: .whitespacesAndNewlines),
              !instance.id.contains("\0"),
              instance.configuration.effectiveContextLength == 32_768,
              instance.configuration.parallelPredictions == 1 else { return nil }
        return instance
    }
}

struct Phase2QualificationGateArtifactManifest {
    let fileCount: Int
    let totalBytes: UInt64
    let sha256: String
    let seal: Phase2QualificationGateArtifactSeal

    static func collect(at root: URL) throws -> Self {
        let manager = FileManager.default
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { throw Phase2QualificationGateRuntimeCollectorError.artifactUnavailable }
        var entries: [(
            relative: String,
            url: URL,
            state: Phase2QualificationGateFileState,
            digest: String
        )] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw Phase2QualificationGateRuntimeCollectorError.artifactUnavailable
            }
            guard values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/"),
                  let state = Phase2QualificationGateFileState(url: url)
            else { throw Phase2QualificationGateRuntimeCollectorError.artifactUnavailable }
            entries.append((
                String(path.dropFirst(rootPath.count + 1)),
                url,
                state,
                try Phase2QualificationGateHash.sha256File(url)
            ))
        }
        entries.sort { $0.relative.utf8.lexicographicallyPrecedes($1.relative.utf8) }
        guard !entries.isEmpty, Set(entries.map(\.relative)).count == entries.count else {
            throw Phase2QualificationGateRuntimeCollectorError.artifactUnavailable
        }
        var aggregate = Data()
        var total: UInt64 = 0
        for entry in entries {
            let (next, overflow) = total.addingReportingOverflow(UInt64(entry.state.size))
            guard !overflow else {
                throw Phase2QualificationGateRuntimeCollectorError.artifactUnavailable
            }
            total = next
            aggregate.append(Data(
                "\(entry.relative)\t\(entry.state.size)\t\(entry.digest)\n".utf8
            ))
        }
        return .init(
            fileCount: entries.count,
            totalBytes: total,
            sha256: Phase2QualificationGateHash.sha256(aggregate),
            seal: .init(
                root: root,
                entries: entries.map {
                    .init(relative: $0.relative, state: $0.state, digest: $0.digest)
                }
            )
        )
    }
}

struct Phase2QualificationGateArtifactSeal: @unchecked Sendable {
    private let root: URL
    private let entries: [Phase2QualificationGateArtifactEntry]

    fileprivate init(
        root: URL,
        entries: [Phase2QualificationGateArtifactEntry]
    ) {
        self.root = root
        self.entries = entries
    }

    func isCurrent() -> Bool {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { return false }
        var current: [(relative: String, state: Phase2QualificationGateFileState)] = []
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ), values.isSymbolicLink != true else { return false }
            guard values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/"),
                  let state = Phase2QualificationGateFileState(url: url)
            else { return false }
            current.append((String(path.dropFirst(rootPath.count + 1)), state))
        }
        current.sort { $0.relative.utf8.lexicographicallyPrecedes($1.relative.utf8) }
        return current.count == entries.count && zip(current, entries).allSatisfy {
            $0.0.relative == $0.1.relative && $0.0.state == $0.1.state
        }
    }

    func isCryptographicallyCurrent() -> Bool {
        guard isCurrent() else { return false }
        let digestsMatch = entries.allSatisfy { entry in
            let file = root.appendingPathComponent(entry.relative)
            return (try? Phase2QualificationGateHash.sha256File(file)) == entry.digest
        }
        return digestsMatch && isCurrent()
    }
}

private struct Phase2QualificationGateArtifactEntry: Equatable, Sendable {
    let relative: String
    let state: Phase2QualificationGateFileState
    let digest: String
}

private struct Phase2QualificationGateFileState: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64

    init?(url: URL) {
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &value) } ?? -1
        }
        guard result == 0, (value.st_mode & S_IFMT) == S_IFREG, value.st_size >= 0 else {
            return nil
        }
        guard let modificationSeconds = Int64(exactly: value.st_mtimespec.tv_sec),
              let modificationNanoseconds = Int64(exactly: value.st_mtimespec.tv_nsec),
              let statusChangeSeconds = Int64(exactly: value.st_ctimespec.tv_sec),
              let statusChangeNanoseconds = Int64(exactly: value.st_ctimespec.tv_nsec)
        else { return nil }
        device = UInt64(truncatingIfNeeded: value.st_dev)
        inode = UInt64(truncatingIfNeeded: value.st_ino)
        size = value.st_size
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.statusChangeSeconds = statusChangeSeconds
        self.statusChangeNanoseconds = statusChangeNanoseconds
    }
}

enum Phase2QualificationGateHash {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256File(_ url: URL) throws -> String {
        guard let before = Phase2QualificationGateFileState(url: url) else {
            throw Phase2QualificationGateRuntimeCollectorError.artifactUnavailable
        }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) } ?? -1
        }
        guard descriptor >= 0 else {
            throw Phase2QualificationGateRuntimeCollectorError.artifactUnavailable
        }
        defer { _ = Darwin.close(descriptor) }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              UInt64(truncatingIfNeeded: opened.st_dev) == before.device,
              UInt64(truncatingIfNeeded: opened.st_ino) == before.inode,
              opened.st_size == before.size,
              (opened.st_mode & S_IFMT) == S_IFREG
        else { throw Phase2QualificationGateRuntimeCollectorError.artifactUnavailable }
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw Phase2QualificationGateRuntimeCollectorError.artifactUnavailable
            }
            hash.update(data: Data(buffer[0..<count]))
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              opened.st_dev == after.st_dev,
              opened.st_ino == after.st_ino,
              opened.st_size == after.st_size,
              opened.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              opened.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              opened.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              opened.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              Phase2QualificationGateFileState(url: url) == before
        else { throw Phase2QualificationGateRuntimeCollectorError.artifactUnavailable }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct Phase2QualificationGateStaticContext {
    let production: Phase2ProductionQualificationPolicy
    let manifest: Phase2ModelProtocolManifest
    let context: Phase2ContextProfile
    let generation: Phase2GenerationProfile
    let hardwareTier: Phase2HardwareTier
    let definition: Phase2StandardModelProfileDefinition

    init(
        production: Phase2ProductionQualificationPolicy,
        provider: Phase2QualifiedProviderIdentity,
        model: Phase2LocalModelDescriptor,
        loadedConfiguration: Phase2LocalModelInstanceConfiguration,
        backingDigest: Phase2ModelBackingDigest,
        environment: Phase2QualificationEnvironmentV2
    ) throws {
        let manifest = Phase2ModelProtocolManifest.productionGroundedReadOnly
        guard manifest.version == 2,
              manifest.protocolProbeCatalog == production.protocolProbeCatalogIdentity,
              manifest.liveQualificationCorpus == production.liveScenarioCatalog.identity,
              manifest.qualificationPolicy == production.policyIdentity,
              model.loadedInstances.count == 1,
              loadedConfiguration == model.loadedInstances[0].configuration,
              loadedConfiguration.effectiveContextLength == 32_768,
              loadedConfiguration.parallelPredictions == 1
        else { throw Phase2QualificationGateRuntimeCollectorError.providerMismatch }
        let context = try Phase2ContextProfile(
            id: "phase2-standard-32k",
            version: 1,
            maximumInputTokens: 32_768,
            reservedOutputTokens: 4_096,
            maximumEvidenceBytes: 2_000_000,
            compactionThresholdTokens: 24_000
        )
        let generation = try Phase2GenerationProfile(
            id: "phase2-grounded-generation",
            version: 2,
            temperature: 0,
            topP: 1,
            seed: nil,
            stopSequences: [],
            reasoningOutputPolicy: .discard
        )
        let hardware = try Phase2HardwareTier(id: "apple-m1-max-64gb", version: 1)
        let artifact = try Phase2ModelArtifactIdentity(
            modelKey: model.key,
            source: production.modelRevision.modelSource,
            type: .language,
            format: .mlx,
            quantizationName: "8bit",
            bitsPerWeight: 8,
            backingDigest: backingDigest
        )
        self.production = production
        self.manifest = manifest
        self.context = context
        self.generation = generation
        hardwareTier = hardware
        definition = .init(
            productionDefinitionIdentity: production.definitionIdentity,
            profileVersion: 2,
            provider: provider,
            artifact: artifact,
            modelRevisionIdentity: production.modelRevision.identity,
            advertisedMaximumContextLength: 262_144,
            loadedConfiguration: loadedConfiguration,
            context: context,
            generation: generation,
            hardwareTier: hardware,
            workflow: .groundedReadOnly,
            authorityCeiling: .groundedReadOnly,
            toolCallMode: .requiredReadOnly,
            structuredOutputMode: .jsonSchema,
            protocolManifest: manifest,
            qualificationPolicy: production.policy,
            inferenceMaximumTokens: 4_096,
            protocolProbeCatalogIdentity: production.protocolProbeCatalogIdentity,
            liveCorpusIdentity: production.liveScenarioCatalog.identity,
            qualificationEnvironment: environment
        )
    }
}

@MainActor
private enum Phase2QualificationGateProviderCollector {
    private static let expectedBundleIdentifier = "ai.elementlabs.lmstudio"
    private static let expectedBuild = "0.4.19+2"

    static func collect(
        endpoint: Phase2LocalProviderEndpoint,
        providerRevision: UInt64,
        inventory: Phase2LocalModelInventory
    ) -> Phase2EndpointBoundProviderObservation? {
        guard providerRevision > 0,
              let loopback = try? Phase2LoopbackEndpoint(validating: endpoint.endpointOrigin),
              let process = Phase2QualificationGateLibprocProviderDiscoverer()
                .uniqueListenerProcess(
                    endpoint: loopback,
                    processObserver: Phase2QualificationLibprocProcessObserver()
                ),
              Phase2QualificationGateProviderCodeAuthority.accepts(process),
              let build = providerBuild(processID: process.processID),
              build == expectedBuild,
              let identity = try? Phase2QualifiedProviderIdentity(
                family: "lm-studio",
                build: build,
                apiCompatibility: "openai-chat-completions-v1",
                endpointTransport: .loopbackHTTP
              ),
              let runtime = try? Phase2EndpointBoundProviderRuntimeIdentity(
                endpoint: endpointIdentity(endpoint),
                processStart: Phase2QualificationGateProcessAuthority
                    .providerProcessStartIdentity(process),
                executableBuild: Phase2QualificationGateProcessAuthority
                    .providerExecutableBuildIdentity(process),
                apiProbe: apiProbeIdentity(inventory)
              )
        else { return nil }
        return .init(
            endpointProfileID: endpoint.profileID,
            endpointGeneration: endpoint.generation,
            providerRevision: providerRevision,
            identity: identity,
            runtimeIdentity: runtime
        )
    }

    private static func endpointIdentity(
        _ endpoint: Phase2LocalProviderEndpoint
    ) throws -> Phase2ProtocolComponentIdentity {
        try Phase2QualificationV2Identity.make(
            id: "phase2.r1.provider-endpoint.v1",
            version: 1,
            object: [
                "generation": Int64(endpoint.generation),
                "origin": endpoint.endpointOrigin,
                "profile_id": endpoint.profileID.uuidString.lowercased(),
                "request_timeout_ms": endpoint.requestTimeoutMilliseconds,
                "resource_timeout_ms": endpoint.resourceTimeoutMilliseconds,
            ]
        )
    }

    private static func apiProbeIdentity(
        _ inventory: Phase2LocalModelInventory
    ) throws -> Phase2ProtocolComponentIdentity {
        try Phase2QualificationV2Identity.make(
            id: "phase2.r1.provider-api-probe.v1",
            version: 1,
            object: [
                "models": inventory.models.map { model in
                    [
                        "format": model.format?.rawValue ?? NSNull(),
                        "key": model.key,
                        "loaded_instances": model.loadedInstances.map { instance in
                            [
                                "configuration": configurationObject(instance.configuration),
                                "id": instance.id,
                            ] as [String: Any]
                        },
                        "maximum_context_length": model.maximumContextLength,
                        "publisher": model.publisher,
                        "quantization_bits": model.quantization?.bitsPerWeight ?? NSNull(),
                        "quantization_name": model.quantization?.name ?? NSNull(),
                        "size_bytes": Int64(model.sizeBytesOnDisk),
                        "type": model.type.rawValue,
                    ] as [String: Any]
                },
                "version": 1,
            ]
        )
    }

    private static func configurationObject(
        _ value: Phase2LocalModelInstanceConfiguration
    ) -> [String: Any] {
        [
            "context_length": value.effectiveContextLength,
            "evaluation_batch_size": value.evaluationBatchSize ?? NSNull(),
            "expert_count": value.expertCount ?? NSNull(),
            "flash_attention": value.flashAttention ?? NSNull(),
            "offloads_kv_cache_to_gpu": value.offloadsKVCacheToGPU ?? NSNull(),
            "parallel_predictions": value.parallelPredictions ?? NSNull(),
        ]
    }

    private static func providerBuild(processID: Int32) -> String? {
        // libproc accepts any adequately bounded caller buffer; 4 KiB covers macOS paths without
        // relying on SDK-overlay-specific convenience constants.
        var buffer = [CChar](repeating: 0, count: 4 * 1_024)
        let count = buffer.withUnsafeMutableBufferPointer {
            proc_pidpath(processID, $0.baseAddress, UInt32($0.count))
        }
        guard count > 0, Int(count) < buffer.count else { return nil }
        buffer[Int(count)] = 0
        let pathBytes = buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
        guard let path = String(bytes: pathBytes, encoding: .utf8), !path.contains("\0") else {
            return nil
        }
        var cursor = URL(fileURLWithPath: path).deletingLastPathComponent()
        while cursor.path != "/" {
            if cursor.pathExtension == "app" {
                let infoURL = cursor.appendingPathComponent("Contents/Info.plist")
                guard let data = try? Data(contentsOf: infoURL),
                      let object = try? PropertyListSerialization.propertyList(
                        from: data,
                        options: [],
                        format: nil
                      ) as? [String: Any],
                      object["CFBundleIdentifier"] as? String == expectedBundleIdentifier,
                      let short = object["CFBundleShortVersionString"] as? String
                else { return nil }
                return short
            }
            cursor.deleteLastPathComponent()
        }
        return nil
    }
}

struct Phase2QualificationGateProviderCodeIdentity: Equatable, Sendable {
    let identifier: String
    let teamIdentifier: String
    let signatureFlags: UInt32
    let runtimeVersion: UInt32
    let leafCertificateCommonName: String
    let certificateCount: Int
    let cdHash: String
    let canonicalBundlePath: String
    let executableSHA256: String
}

enum Phase2QualificationGateProviderCodeIdentityPolicy {
    private static let expectedIdentifier = "ai.elementlabs.lmstudio"
    private static let expectedTeamIdentifier = "D65G88RHWN"
    private static let expectedLeafCertificate =
        "Developer ID Application: Element Labs Inc (D65G88RHWN)"
    private static let expectedCDHash = "c67b3400427d8fdbb4bf8680546426c7740ac3dc"
    private static let expectedBundlePath = "/Applications/LM Studio.app"
    private static let expectedExecutableSHA256 =
        "b24d25bcf1d2eac3456d6fb67a8aee6f0ea9cb037a5a812d68ab739d666a0168"
    private static let hardenedRuntimeFlag: UInt32 = 0x10000
    private static let adHocFlag: UInt32 = 0x0002

    static func accepts(_ value: Phase2QualificationGateProviderCodeIdentity) -> Bool {
        value.identifier == expectedIdentifier
            && value.teamIdentifier == expectedTeamIdentifier
            && value.signatureFlags & hardenedRuntimeFlag == hardenedRuntimeFlag
            && value.signatureFlags & adHocFlag == 0
            && value.runtimeVersion > 0
            && value.leafCertificateCommonName == expectedLeafCertificate
            && value.certificateCount >= 3
            && value.cdHash == expectedCDHash
            && value.canonicalBundlePath == expectedBundlePath
            && value.executableSHA256 == expectedExecutableSHA256
    }

    static func acceptsStandalone(
        _ value: Phase2QualificationGateProviderCodeIdentity,
        homeDirectory: URL
    ) -> Bool {
        let policy = Phase2QualificationProviderAdmissionPolicy.self
        let expected = homeDirectory.appendingPathComponent(policy.executableRelativePath)
        return value.identifier == policy.identifier
            && value.teamIdentifier == policy.teamIdentifier
            && value.signatureFlags & hardenedRuntimeFlag == hardenedRuntimeFlag
            && value.signatureFlags & adHocFlag == 0
            && value.runtimeVersion > 0
            && value.leafCertificateCommonName == expectedLeafCertificate
            && value.certificateCount >= 3
            && value.cdHash == policy.cdHash
            && value.canonicalBundlePath == expected.standardizedFileURL.path
            && value.executableSHA256 == policy.executableSHA256
    }
}

private enum Phase2QualificationGateProviderCodeAuthority {
    private static let requirementExpression =
        "identifier \"ai.elementlabs.lmstudio\" and anchor apple generic and "
        + "certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and "
        + "certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and "
        + "certificate leaf[subject.OU] = D65G88RHWN"
    private static let guestLookupFlags =
        Phase2QualificationGateSecurityValidationFlags.guestLookup
    private static let dynamicValidityFlags =
        Phase2QualificationGateSecurityValidationFlags.dynamicValidity

    static func accepts(
        _ observation: Phase2QualificationProcessObservation,
        selector: Phase2QualificationProfileSelector = .historicalF4C
    ) -> Bool {
        guard observation.processID > 1, observation.hasValidIdentity,
              let identity = identity(
                  processID: observation.processID,
                  executableSHA256: observation.executableIdentity.sha256,
                  selector: selector
              )
        else { return false }
        switch selector {
        case .historicalF4C:
            return Phase2QualificationGateProviderCodeIdentityPolicy.accepts(identity)
        case .qwen38V2Q6K:
            return Phase2QualificationGateProviderCodeIdentityPolicy.acceptsStandalone(
                identity, homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
        }
    }

    private static func identity(
        processID: Int32,
        executableSHA256: String,
        selector: Phase2QualificationProfileSelector
    ) -> Phase2QualificationGateProviderCodeIdentity? {
        var dynamicCode: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: processID)]
            as CFDictionary
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            guestLookupFlags,
            &dynamicCode
        ) == errSecSuccess, let dynamicCode,
              let requirement = requirement(selector: selector),
              SecCodeCheckValidityWithErrors(
                  dynamicCode,
                  dynamicValidityFlags,
                  requirement,
                  nil
              ) == errSecSuccess
        else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamicCode, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode,
              let signing = signingInformation(staticCode),
              let identifier = signing[kSecCodeInfoIdentifier as String] as? String,
              let teamIdentifier = signing[kSecCodeInfoTeamIdentifier as String] as? String,
              let signatureFlags = (signing[kSecCodeInfoFlags as String] as? NSNumber)?
                .uint32Value,
              let runtimeVersion = (signing[kSecCodeInfoRuntimeVersion as String] as? NSNumber)?
                .uint32Value,
              let cdHash = signing[kSecCodeInfoUnique as String] as? Data,
              let certificates = signing[kSecCodeInfoCertificates as String]
                as? [SecCertificate],
              let leaf = certificates.first,
              let leafName = certificateCommonName(leaf),
              let bundlePath = canonicalCodePath(staticCode, selector: selector)
        else { return nil }

        return .init(
            identifier: identifier,
            teamIdentifier: teamIdentifier,
            signatureFlags: signatureFlags,
            runtimeVersion: runtimeVersion,
            leafCertificateCommonName: leafName,
            certificateCount: certificates.count,
            cdHash: cdHash.map { String(format: "%02x", $0) }.joined(),
            canonicalBundlePath: bundlePath,
            executableSHA256: executableSHA256
        )
    }

    private static func requirement(selector: Phase2QualificationProfileSelector) -> SecRequirement? {
        var value: SecRequirement?
        let expression = selector == .historicalF4C
            ? requirementExpression : Phase2QualificationProviderAdmissionPolicy.designatedRequirement
        guard SecRequirementCreateWithString(
            expression as CFString,
            SecCSFlags(),
            &value
        ) == errSecSuccess else { return nil }
        return value
    }

    private static func signingInformation(_ code: SecStaticCode) -> [String: Any]? {
        var value: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &value
        ) == errSecSuccess else { return nil }
        return value as? [String: Any]
    }

    private static func canonicalCodePath(
        _ code: SecStaticCode, selector: Phase2QualificationProfileSelector
    ) -> String? {
        var value: CFURL?
        guard SecCodeCopyPath(code, SecCSFlags(), &value) == errSecSuccess,
              let value else { return nil }
        var cursor = (value as URL).resolvingSymlinksInPath().standardizedFileURL
        if selector == .qwen38V2Q6K {
            let original = (value as URL).standardizedFileURL
            guard original.path == cursor.path else { return nil }
            return cursor.path
        }
        while cursor.path != "/", cursor.pathExtension != "app" {
            cursor.deleteLastPathComponent()
        }
        guard cursor.pathExtension == "app" else { return nil }
        return cursor.path
    }

    private static func certificateCommonName(_ value: SecCertificate) -> String? {
        var name: CFString?
        guard SecCertificateCopyCommonName(value, &name) == errSecSuccess else { return nil }
        return name as String?
    }
}

private enum Phase2QualificationGateDirectCatalogCollector {
    static func collect(
        endpoint: Phase2LocalProviderEndpoint
    ) -> Phase2LocalModelInventory? {
        guard let loopback = try? Phase2LoopbackEndpoint(validating: endpoint.endpointOrigin),
              let data = Phase2QualificationGateSynchronousHTTP.get(
                url: loopback.origin.appendingPathComponent("api/v1/models"),
                maximumBytes: Phase2NativeModelCatalogDecoder.maximumEnvelopeBytes
              ),
              let catalog = try? Phase2NativeModelCatalogDecoder().decode(data),
              let models = try? catalog.models.map(mapModel)
        else { return nil }
        return try? .init(
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            models: models
        )
    }

    private static func mapModel(_ model: Phase2NativeModel) throws -> Phase2LocalModelDescriptor {
        let type: Phase2LocalModelType = switch model.kind {
        case .llm: .language
        case .embedding: .embedding
        }
        let format: Phase2LocalModelFormat? = switch model.format {
        case .gguf: .gguf
        case .mlx: .mlx
        case nil: nil
        }
        return .init(
            type: type,
            publisher: model.publisher,
            key: model.key,
            displayName: model.displayName,
            architecture: model.architecture,
            quantization: model.quantization.map {
                .init(name: $0.name, bitsPerWeight: $0.bitsPerWeight)
            },
            sizeBytesOnDisk: model.sizeBytes,
            parameterCountDescription: model.parameters,
            maximumContextLength: model.maximumContextLength,
            format: format,
            capabilities: model.capabilities.map { capabilities in
                .init(
                    supportsVision: capabilities.supportsVision,
                    trainedForToolUse: capabilities.trainedForToolUse,
                    reasoning: capabilities.reasoning.map { reasoning in
                        .init(
                            allowedOptions: reasoning.allowedOptions.compactMap {
                                Phase2LocalModelReasoningOption(rawValue: $0.rawValue)
                            },
                            defaultOption: Phase2LocalModelReasoningOption(
                                rawValue: reasoning.defaultOption.rawValue
                            )!
                        )
                    }
                )
            },
            summary: model.description,
            variants: model.variants ?? [],
            providerSelectedVariant: model.selectedVariant,
            loadedInstances: model.loadedInstances.map {
                .init(
                    id: $0.id,
                    configuration: .init(
                        effectiveContextLength: $0.configuration.contextLength,
                        evaluationBatchSize: $0.configuration.evaluationBatchSize,
                        parallelPredictions: $0.configuration.parallelPredictions,
                        flashAttention: $0.configuration.flashAttention,
                        expertCount: $0.configuration.expertCount,
                        offloadsKVCacheToGPU: $0.configuration.offloadsKVCacheToGPU
                    )
                )
            }
        )
    }
}

private enum Phase2QualificationGateSynchronousHTTP {
    static func get(url: URL, maximumBytes: Int) -> Data? {
        guard maximumBytes > 0 else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesHTTPSEnable as String: false,
            kCFNetworkProxiesSOCKSEnable as String: false,
            kCFNetworkProxiesProxyAutoConfigEnable as String: false,
            kCFNetworkProxiesProxyAutoDiscoveryEnable as String: false,
        ]
        let delegate = Phase2QualificationGateBoundedHTTPDelegate(
            expectedURL: url,
            maximumBytes: maximumBytes
        )
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: queue
        )
        defer { session.invalidateAndCancel() }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 5
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let task = session.dataTask(with: request)
        task.resume()
        guard delegate.waitForCompletion(timeout: .now() + 16) else {
            task.cancel()
            return nil
        }
        return delegate.result()
    }
}

private final class Phase2QualificationGateBoundedHTTPDelegate:
    NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable
{
    private let expectedURL: URL
    private let maximumBytes: Int
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private var body = Data()
    private var acceptedResponse = false
    private var failed = false
    private var completed = false

    init(expectedURL: URL, maximumBytes: Int) {
        self.expectedURL = expectedURL
        self.maximumBytes = maximumBytes
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.withLock { failed = true }
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              response.url == expectedURL,
              response.statusCode == 200,
              let type = response.value(forHTTPHeaderField: "Content-Type")?
                .split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              type == "application/json",
              response.expectedContentLength == NSURLSessionTransferSizeUnknown
                || response.expectedContentLength <= Int64(maximumBytes)
        else {
            lock.withLock { failed = true }
            completionHandler(.cancel)
            return
        }
        lock.withLock { acceptedResponse = true }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard acceptedResponse, !failed,
                  data.count <= maximumBytes,
                  body.count <= maximumBytes - data.count
            else {
                failed = true
                return true
            }
            body.append(data)
            return false
        }
        if shouldCancel { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.withLock {
            if error != nil { failed = true }
            completed = true
        }
        completion.signal()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        lock.withLock { failed = true }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func waitForCompletion(timeout: DispatchTime) -> Bool {
        completion.wait(timeout: timeout) == .success
    }

    func result() -> Data? {
        lock.withLock {
            guard completed, acceptedResponse, !failed, body.count <= maximumBytes else {
                return nil
            }
            return body
        }
    }
}

@MainActor
struct Phase2QualificationGateEnvironmentSeal {
    let environment: Phase2QualificationEnvironmentV2
    private let buildAuthority: Phase2QualificationGateBuildAuthority

    fileprivate init(
        environment: Phase2QualificationEnvironmentV2,
        buildAuthority: Phase2QualificationGateBuildAuthority
    ) {
        self.environment = environment
        self.buildAuthority = buildAuthority
    }

    func isCurrent() -> Bool {
        buildAuthority.isCurrent()
            && Phase2QualificationGateHostSnapshot.capture()?.matches(environment) == true
    }
}

private struct Phase2QualificationGateHostSnapshot {
    let operatingSystemVersion: String
    let operatingSystemBuild: String
    let architecture: String
    let hardwareModel: String
    let processorFamily: String
    let physicalMemoryBytes: UInt64
    let physicalCoreCount: Int
    let logicalCoreCount: Int
    let performanceCoreCount: Int
    let efficiencyCoreCount: Int

    static func capture() -> Self? {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard let build = Phase2QualificationGateCommand.run(
            "/usr/bin/sw_vers", ["-buildVersion"]
        ), let architecture = Phase2QualificationGateCommand.run(
            "/usr/bin/uname", ["-m"]
        ), let model = sysctlString("hw.model"),
           let processor = sysctlString("machdep.cpu.brand_string"),
           let memory = sysctlUInt64("hw.memsize"),
           let physical = sysctlInt("hw.physicalcpu"),
           let logical = sysctlInt("hw.logicalcpu"),
           let performance = sysctlInt("hw.perflevel0.physicalcpu"),
           let efficiency = sysctlInt("hw.perflevel1.physicalcpu")
        else { return nil }
        return .init(
            operatingSystemVersion:
                "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            operatingSystemBuild: build,
            architecture: architecture,
            hardwareModel: model,
            processorFamily: processor,
            physicalMemoryBytes: memory,
            physicalCoreCount: physical,
            logicalCoreCount: logical,
            performanceCoreCount: performance,
            efficiencyCoreCount: efficiency
        )
    }

    func matches(_ environment: Phase2QualificationEnvironmentV2) -> Bool {
        operatingSystemVersion == environment.operatingSystemVersion
            && operatingSystemBuild == environment.operatingSystemBuild
            && architecture == environment.architecture
            && hardwareModel == environment.hardwareModel
            && processorFamily == environment.processorFamily
            && physicalMemoryBytes == environment.physicalMemoryBytes
            && physicalCoreCount == environment.physicalCoreCount
            && logicalCoreCount == environment.logicalCoreCount
            && performanceCoreCount == environment.performanceCoreCount
            && efficiencyCoreCount == environment.efficiencyCoreCount
    }

    private static func sysctlString(_ name: String) -> String? {
        Phase2QualificationGateCommand.run("/usr/sbin/sysctl", ["-n", name])
    }

    private static func sysctlInt(_ name: String) -> Int? {
        sysctlString(name).flatMap(Int.init)
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        sysctlString(name).flatMap(UInt64.init)
    }
}

private enum Phase2QualificationGateEnvironmentCollector {
    @MainActor
    static func collectEnvironment(
        buildAuthority: Phase2QualificationGateBuildAuthority
    ) throws -> Phase2QualificationGateEnvironmentSeal {
        guard Bundle.main.bundleIdentifier == "org.macscope.app",
              let shortVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String,
              let bundleVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
              ) as? String,
              buildAuthority.isCurrent(),
              let host = Phase2QualificationGateHostSnapshot.capture()
        else { throw Phase2QualificationGateRuntimeCollectorError.environmentUnavailable }
        let provenance = buildAuthority.provenance
        let observation = Phase2QualificationEnvironmentObservation(
            bundleShortVersion: shortVersion,
            bundleVersion: bundleVersion,
            macScopeCommit: provenance.gitHeadCommit,
            appExecutableDigest: buildAuthority.appExecutableSHA256,
            workerExecutableDigest: buildAuthority.workerExecutableSHA256,
            signingRequirementDigest: buildAuthority.signingRequirementSHA256,
            xcodeVersion: provenance.xcodeVersion,
            xcodeBuild: provenance.xcodeBuild,
            swiftCompilerVersion: provenance.swiftCompilerVersion,
            sdkVersion: provenance.sdkVersion,
            sdkBuild: provenance.sdkBuild,
            operatingSystemVersion: host.operatingSystemVersion,
            operatingSystemBuild: host.operatingSystemBuild,
            architecture: host.architecture,
            hardwareModel: host.hardwareModel,
            processorFamily: host.processorFamily,
            physicalMemoryBytes: host.physicalMemoryBytes,
            physicalCoreCount: host.physicalCoreCount,
            logicalCoreCount: host.logicalCoreCount,
            performanceCoreCount: host.performanceCoreCount,
            efficiencyCoreCount: host.efficiencyCoreCount
        )
        let environment = try Phase2QualificationEnvironmentCollector().collect(
            observation: observation,
            hardwarePolicy: .thisM1Max64GiB
        )
        return .init(
            environment: environment,
            buildAuthority: buildAuthority
        )
    }
}

private enum Phase2QualificationGateCommand {
    static func run(
        _ executable: String,
        _ arguments: [String],
        mergeError: Bool = false
    ) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = mergeError ? output : FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count <= 16 * 1_024,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
