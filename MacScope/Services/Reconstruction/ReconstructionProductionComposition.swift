import Darwin
import Foundation
import Security

enum ReconstructionProductionCompositionError: Error, Equatable, Sendable {
    case productionBundleInvalid
    case productionProvenanceInvalid
    case nativeAuthorityRetired
    case conflictingImageAuthority
}

/// App-only construction of the complete production Reconstruction job graph.
///
/// The graph becomes reachable only after the signed app's canonical Release provenance resource
/// validates against the app code seal. One job session owns one controller and one lazily minted
/// native admission. Immutable committed cuts may replace their lightweight resolver/pool/scheduler
/// child, but can neither select another job nor mint another native owner.
enum ReconstructionProductionComposition {
    private static let gibibyte: UInt64 = 1_073_741_824
    private static let provenanceRelativePath =
        "Contents/Resources/MacScopeBuildProvenance.json"
    private static let sealedProvenanceRelativePath =
        "Resources/MacScopeBuildProvenance.json"

    /// Shared outer/inner ceiling: common ten-core M1 Max uses two workers with three
    /// analysis slots each. Logical scheduling remains under GCD; this is not core affinity.
    /// Resident estimates and width are provisional pending the qualification benchmark.
    static let productionAnalysisBudget: ReconstructionAnalysisProviderPoolBudget = {
        let slots = AnalysisHostResourcePolicy.reconstructionParallelism(
            processorCount: ProcessInfo.processInfo.activeProcessorCount)
        return .init(maximumActiveAnalyses: slots.outer,
            estimatedResidentBytesPerAnalysis: 2 * gibibyte,
            reservedHostBytes: 4 * gibibyte,
            maximumInnerParallelism: slots.inner)
    }()

    static func jobSessionFactoryBuilder(
        nativeDecompilerRuntime: NativeDecompilerRuntimeRegistry,
        appBundleURL: URL = Bundle.main.bundleURL
    ) -> ReconstructionJobSessionFactoryBuilder? {
        guard let releaseProvenance = try? validatedProductionProvenance(
            appBundleURL: appBundleURL
        ) else { return nil }

        return { inferenceCoordinator in
            { workspaceID, durableJobID, owner, store in
                try await makeJobSession(
                    workspaceID: workspaceID,
                    durableJobID: durableJobID,
                    owner: owner,
                    store: store,
                    inferenceCoordinator: inferenceCoordinator,
                    nativeDecompilerRuntime: nativeDecompilerRuntime,
                    modelProducerContext: .production(provenance: releaseProvenance)
                )
            }
        }
    }

    /// The same production job graph for an unsealed (Debug, dev-loop) test host, which has no
    /// canonical Release provenance. The caller supplies the model producer identity a sealed
    /// Release derives from its provenance. Tests only; app composition never reaches it.
    /// `nativeTaskDecompiler` wraps the admitted production native adapter (e.g. to force a native
    /// fail-closed for one function and observe the D13 MacIR fallback).
    static func unsealedHostJobSessionFactoryBuilderForTesting(
        nativeDecompilerRuntime: NativeDecompilerRuntimeRegistry,
        modelProducerContext: ReconstructionModelProducerIdentityContext,
        nativeTaskDecompiler: (@Sendable (any ReconstructionNativeTaskDecompiling)
            -> any ReconstructionNativeTaskDecompiling)? = nil,
        sourceTransport: (@Sendable (any ShellBrokerXPCTransport) -> any ShellBrokerXPCTransport)? = nil
    ) -> ReconstructionJobSessionFactoryBuilder {
        { inferenceCoordinator in
            { workspaceID, durableJobID, owner, store in
                try await makeJobSession(
                    workspaceID: workspaceID,
                    durableJobID: durableJobID,
                    owner: owner,
                    store: store,
                    inferenceCoordinator: inferenceCoordinator,
                    nativeDecompilerRuntime: nativeDecompilerRuntime,
                    modelProducerContext: modelProducerContext,
                    nativeTaskDecompiler: nativeTaskDecompiler,
                    sourceTransport: sourceTransport
                )
            }
        }
    }

    static func sourceStageParent() throws -> URL {
        let url = MacScopeWorkRoot.url.appendingPathComponent("MacScopeSourceExecution", isDirectory: true)
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST {
            throw ReconstructionProductionCompositionError.productionBundleInvalid
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o022) == 0,
              url.resolvingSymlinksInPath().path == url.path else {
            throw ReconstructionProductionCompositionError.productionBundleInvalid
        }
        return url
    }

    static func productionModelProducerContext(
        appBundleURL: URL
    ) throws -> ReconstructionModelProducerIdentityContext {
        let provenance = try validatedProductionProvenance(
            appBundleURL: appBundleURL
        )
        return ReconstructionModelProducerIdentityContext.production(
            provenance: provenance
        )
    }

    @MainActor
    private static func makeJobSession(
        workspaceID: UUID,
        durableJobID: UUID,
        owner: ReconstructionDatabaseOwner,
        store: WorkspaceStore,
        inferenceCoordinator: any ReconstructionReadyInferenceCoordinating,
        nativeDecompilerRuntime: NativeDecompilerRuntimeRegistry,
        modelProducerContext: ReconstructionModelProducerIdentityContext,
        nativeTaskDecompiler: (@Sendable (any ReconstructionNativeTaskDecompiling)
            -> any ReconstructionNativeTaskDecompiling)? = nil,
        sourceTransport: (@Sendable (any ShellBrokerXPCTransport) -> any ShellBrokerXPCTransport)? = nil
    ) async throws -> ReconstructionJobSession {
        let maximumConcurrentTasks = try productionAnalysisBudget.width()
        let persistence = ReconstructionDatabaseJobPersistence(
            workspaceID: workspaceID,
            owner: owner
        )
        let nativeAuthority = ReconstructionProductionJobNativeAuthority(
            durableJobID: durableJobID,
            factory: ReconstructionNativeDecompilerAdmissionFactory(
                runtime: nativeDecompilerRuntime,
                durable: persistence
            )
        )
        let receiptAuthor = ReconstructionProductionReceiptPlanAuthor(modelProducerContext: modelProducerContext)
        let sourceAuthority = ReconstructionProductionJobSourceAuthority(durableJobID: durableJobID,
            transportWrapper: sourceTransport)
        let sourceRecovery = ReconstructionSourceOriginalRecovery(
            workflowProvider: { try await sourceAuthority.workflow() },
            stageParent: try sourceStageParent())
        let executionController = ReconstructionProductionBatchExecutionController(
            durableJobID: durableJobID,
            builder: { basis, _ in
                let resolver = try ReconstructionHeadlessAnalysisRequestResolver(
                    manifest: basis.manifest,
                    attachmentSources: basis.attachmentSources,
                    imagesByOccurrence: try imagesByOccurrence(in: basis)
                )
                let pool = try ReconstructionAnalysisProviderPool(
                    factory: ReconstructionDefaultAnalysisProviderFactory(resourceBudget: .init(
                        maximumParallelism: productionAnalysisBudget.maximumInnerParallelism)),
                    budget: productionAnalysisBudget,
                    resourceMonitor: AnalysisHostResourceMonitor(),
                    globalAdmission: .shared
                )
                let admittedNative: any ReconstructionNativeTaskDecompiling = try await nativeAuthority.adapter()
                let native = nativeTaskDecompiler.map { $0(admittedNative) } ?? admittedNative
                let sourceExecutor: ReconstructionProductionSourceTaskExecutor?
                if basis.tasks.contains(where: { $0.identity.kind == .executeSource
                    && ($0.state == .pending || $0.state == .running) }) {
                    let hasPendingOracle = basis.tasks.contains { $0.identity.kind == .executeSource
                        && $0.identity.operationContractIdentity == ReconstructionSourceExecutionTaskContract.oracle
                        && ($0.state == .pending || $0.state == .running) }
                    let workflow: ReconstructionSourceExecutionWorkflow
                    do { workflow = try await sourceAuthority.workflow() }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        guard hasPendingOracle else { throw error }
                        let diagnostic = "Original source tooling is unavailable: " + String(describing: error)
                        throw ReconstructionSourceOriginalRecoveryFailure.unavailable(
                            String(decoding: diagnostic.utf8.prefix(1_024), as: UTF8.self))
                    }
                    var original: ReconstructionProductionSourceTaskResolution.Original?
                    if let task = basis.tasks.first(where: { $0.identity.kind == .executeSource
                        && $0.identity.operationContractIdentity == ReconstructionSourceExecutionTaskContract.oracle
                        && ($0.state == .pending || $0.state == .running) }),
                       case .function(let function)? = task.identity.subject,
                       let session = try await sourceRecovery.session(for: basis) {
                        let prepared = try await session.preparedOriginal(projectID: basis.project.projectID,
                            jobID: basis.job.jobID, function: function,
                            committedFunctions: ReconstructionSourceOriginalSessionRegistry.committedFunctions(in: basis))
                        original = .prepared(prepared, function: function)
                    }
                    sourceExecutor = ReconstructionProductionSourceTaskExecutor(
                        resolver: ReconstructionProductionSourceCutResolver(basis: basis,
                            stageParent: try sourceStageParent(), original: original), workflow: workflow,
                        oracleAssembler: ReconstructionProductionSourceCutOracleAssembler(basis: basis,
                            producer: try receiptAuthor.makeSourceToolProducer(contract: ReconstructionSourceExecutionTaskContract.oracle)))
                } else { sourceExecutor = nil }
                let executor = ReconstructionBatchTaskExecutor(
                    resolver: resolver, headless: ReconstructionHeadlessAnalysisExecutor(pool: pool),
                    native: native, sourceExecutor: sourceExecutor)

                return ReconstructionBatchScheduler(
                    durableJobID: durableJobID,
                    executor: executor
                )
            },
            retireJobAuthority: {
                await sourceRecovery.retire()
                await sourceAuthority.retire()
                await nativeAuthority.retire()
            }
        )

        let evidenceQueryProducer = try receiptAuthor.makeToolProducer(
            operationID: .evidenceQuery
        )
        let analysisRefreshProducer = try receiptAuthor.makeToolProducer(
            operationID: .analysisMacScopeRefresh
        )
        let basisRegistry = ReconstructionProductionRoundBasisRegistry()
        let cutProvider = ReconstructionProductionCommittedRoundCutProvider(
            workspaceID: workspaceID,
            owner: owner,
            batchExecutionBuilder: executionController,
            preparedRoundBuilder: try ReconstructionProductionPreparedRoundBuilder(
                evidenceQueryProducer: evidenceQueryProducer,
                analysisRefreshProducer: analysisRefreshProducer,
                sourceOriginalRecovery: sourceRecovery,
                replayOwner: owner
            ),
            basisRegistry: basisRegistry,
            maximumConcurrentTasks: maximumConcurrentTasks
        )
        let planBuilder = ReconstructionProductionRoundPlanBuilder(
            basisRegistry: basisRegistry,
            receiptAuthor: receiptAuthor
        )
        let materializer = ReconstructionProductionJobRoundMaterializer(
            cutProvider: cutProvider,
            planBuilder: planBuilder
        )
        let planner = ReconstructionProductionJobRoundPlanner(
            materializer: materializer,
            inference: inferenceCoordinator,
            projectors: productionProjectors,
            replayOwner: owner,
            replayWorkspaceID: workspaceID
        )
        let coordinator = store.makeReconstructionJobCoordinator(
            owner: owner,
            planner: planner
        )
        await coordinator.configureExecutionBudget(owner: owner, workspaceID: workspaceID)
        return ReconstructionJobSession(
            durableJobID: durableJobID,
            coordinator: coordinator,
            scheduler: executionController
        )
    }

    private static var productionProjectors: [any ReconstructionToolProjecting] {
        [
            ReconstructionCheckpointToolProjector(),
            ReconstructionCorpusToolProjector(),
            ReconstructionDecompilerToolProjector(),
            ReconstructionEvidenceToolProjector(),
            ReconstructionGapsToolProjector(),
            ReconstructionImageFunctionToolProjector(),
        ]
    }

    private static func imagesByOccurrence(
        in basis: ReconstructionProductionRoundBasis
    ) throws -> [ReconstructionArtifactOccurrenceID: ReconstructionImageBinding] {
        var images: [ReconstructionArtifactOccurrenceID: ReconstructionImageBinding] = [:]
        for task in basis.tasks {
            let coordinate: (
                ReconstructionArtifactCoordinate,
                ReconstructionImageBinding
            )? = switch task.identity.subject {
            case .image(let image): (image.artifact, image.image)
            case .function(let function): (function.artifact, function.image)
            case .artifact, .none: nil
            }
            guard let (artifact, image) = coordinate else { continue }
            if let existing = images[artifact.occurrenceID], existing != image {
                throw ReconstructionProductionCompositionError.conflictingImageAuthority
            }
            images[artifact.occurrenceID] = image
        }
        return images
    }

    private static func validatedProductionProvenance(
        appBundleURL: URL
    ) throws -> Phase2QualificationGateBuildProvenance {
        let canonicalBundleURL = appBundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard appBundleURL.isFileURL,
              appBundleURL.path == canonicalBundleURL.path,
              appBundleURL.pathExtension == "app" else {
            throw ReconstructionProductionCompositionError.productionBundleInvalid
        }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            appBundleURL as CFURL,
            SecCSFlags(),
            &code
        ) == errSecSuccess, let code else {
            throw ReconstructionProductionCompositionError.productionBundleInvalid
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            Phase2AIWorkerPeerRequirement.app as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidityWithErrors(
                code,
                Phase2QualificationGateSecurityValidationFlags.staticValidity,
                requirement,
                nil
              ) == errSecSuccess else {
            throw ReconstructionProductionCompositionError.productionBundleInvalid
        }

        let provenanceBytes = try ReconstructionProductionRegularFile.read(
            appBundleURL.appendingPathComponent(provenanceRelativePath),
            maximumBytes: Int64(Phase2QualificationGateBuildProvenance.maximumBytes)
        )
        let provenance: Phase2QualificationGateBuildProvenance
        do {
            provenance = try Phase2QualificationGateBuildProvenance.parseCanonical(
                provenanceBytes
            )
        } catch {
            throw ReconstructionProductionCompositionError.productionProvenanceInvalid
        }
        guard SecCodeValidateFileResource(
            code,
            sealedProvenanceRelativePath as CFString,
            provenanceBytes as CFData,
            SecCSFlags()
        ) == errSecSuccess else {
            throw ReconstructionProductionCompositionError.productionProvenanceInvalid
        }
        return provenance
    }
}

/// Coalesces the one native admission for a durable job and keeps it unminted until a committed
/// batch cut actually executes. That allows a reopened paused job to construct its session before
/// the coordinator durably resumes it, while still preventing sibling-job or per-cut admissions.
private actor ReconstructionProductionJobNativeAuthority {
    private struct Opening {
        let token: UUID
        let task: Task<any NativeDecompilerOwnerAdmission, Error>
    }

    let durableJobID: UUID
    private let factory: ReconstructionNativeDecompilerAdmissionFactory
    private var opening: Opening?
    private var retainedAdapter: ReconstructionNativeDecompilerAdapter?
    private var isRetired = false

    init(
        durableJobID: UUID,
        factory: ReconstructionNativeDecompilerAdmissionFactory
    ) {
        self.durableJobID = durableJobID
        self.factory = factory
    }

    func adapter() async throws -> ReconstructionNativeDecompilerAdapter {
        if let retainedAdapter { return retainedAdapter }
        guard !isRetired else {
            throw ReconstructionProductionCompositionError.nativeAuthorityRetired
        }

        let opening: Opening
        if let current = self.opening {
            opening = current
        } else {
            let factory = self.factory
            let jobID = durableJobID
            let created = Opening(
                token: UUID(),
                task: Task {
                    try await factory.admission(forDurableJobID: jobID)
                }
            )
            self.opening = created
            opening = created
        }

        let admission: any NativeDecompilerOwnerAdmission
        do {
            admission = try await opening.task.value
        } catch {
            if self.opening?.token == opening.token { self.opening = nil }
            throw error
        }
        if let retainedAdapter { return retainedAdapter }
        guard !isRetired else {
            throw ReconstructionProductionCompositionError.nativeAuthorityRetired
        }
        guard self.opening?.token == opening.token else {
            await admission.retire()
            throw ReconstructionProductionCompositionError.nativeAuthorityRetired
        }
        let adapter = ReconstructionNativeDecompilerAdapter(admission: admission)
        retainedAdapter = adapter
        self.opening = nil
        return adapter
    }

    func retire() async {
        guard !isRetired else { return }
        isRetired = true
        let adapter = retainedAdapter
        retainedAdapter = nil
        let opening = self.opening
        self.opening = nil
        if let adapter {
            await adapter.retire()
        } else if let opening, let admission = try? await opening.task.value {
            await admission.retire()
        }
    }
}

/// Descriptor-bound, no-follow read used before validating the resource against the app's code
/// seal. It mirrors the qualification gate's private bounded-reader contract without widening
/// that security implementation to general in-module callers.
private enum ReconstructionProductionRegularFile {
    static func read(_ url: URL, maximumBytes: Int64) throws -> Data {
        guard maximumBytes >= 0 else {
            throw ReconstructionProductionCompositionError.productionProvenanceInvalid
        }
        var before = stat()
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path, Darwin.lstat(path, &before) == 0,
                  (before.st_mode & S_IFMT) == S_IFREG,
                  before.st_size >= 0,
                  before.st_size <= maximumBytes else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw ReconstructionProductionCompositionError.productionProvenanceInvalid
        }
        defer { Darwin.close(descriptor) }

        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              sameFile(before, opened) else {
            throw ReconstructionProductionCompositionError.productionProvenanceInvalid
        }
        var data = Data()
        data.reserveCapacity(Int(opened.st_size))
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ReconstructionProductionCompositionError.productionProvenanceInvalid
            }
            let (next, overflow) = total.addingReportingOverflow(Int64(count))
            guard !overflow, next <= maximumBytes else {
                throw ReconstructionProductionCompositionError.productionProvenanceInvalid
            }
            data.append(contentsOf: buffer[0..<count])
            total = next
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              sameFile(opened, after),
              total == after.st_size else {
            throw ReconstructionProductionCompositionError.productionProvenanceInvalid
        }
        return data
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

/// One lazy tool capture and broker transport per existing job session. Process lifetime remains
/// owned by the existing ShellBroker; immutable cut children use this same transport.
private actor ReconstructionProductionJobSourceAuthority {
    let durableJobID: UUID
    private let transport: any ShellBrokerXPCTransport
    private var captured: ReconstructionSourceExecutionWorkflow?
    private var retired = false
    /// `transportWrapper` is a test-only seam (unsealed builder) around the production broker.
    init(durableJobID: UUID,
         transportWrapper: (@Sendable (any ShellBrokerXPCTransport) -> any ShellBrokerXPCTransport)? = nil) {
        self.durableJobID = durableJobID
        let broker = NSXPCShellBrokerTransport()
        transport = transportWrapper.map { $0(broker) } ?? broker
    }
    func workflow() throws -> ReconstructionSourceExecutionWorkflow {
        guard !retired else { throw ReconstructionProductionCompositionError.nativeAuthorityRetired }
        if let captured { return captured }
        let workflow = ReconstructionSourceExecutionWorkflow(transport: transport,
            toolAuthority: try .capture())
        captured = workflow
        return workflow
    }
    func retire() async {
        retired = true
        await transport.reset()
        captured = nil
    }
}
