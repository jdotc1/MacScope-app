import Foundation

/// Immutable construction authority for one targetless retained Xcode-bundled LLDB interpreter.
///
/// The plan deliberately carries no PID, process name, executable target, attach request, lease,
/// target authority, or semantic command. Its timeout is frozen for the later exact transaction;
/// constructing the transport itself writes no target command.
struct PersistentLLDBTargetlessTransportPlan: Sendable {
    let processLaunchPlan: PersistentLLDBCLIProcessLaunchPlan
    let timeout: Duration

    @MainActor
    static func make(
        toolchain: DebuggerLLDBToolchain,
        environment: [String: String],
        fallbackWorkingDirectory: String,
        timeout: Duration,
        fileManager: FileManager = .default
    ) throws -> PersistentLLDBTargetlessTransportPlan {
        guard timeout > .zero else {
            throw DebuggerClientError.invalidConfiguration(
                "Targetless LLDB transport requires a positive timeout."
            )
        }
        let processLaunchPlan = try PersistentLLDBCLIProcessPlanFactory.make(
            toolchain: toolchain,
            environment: environment,
            workingDirectory: fallbackWorkingDirectory,
            fileManager: fileManager
        )
        return PersistentLLDBTargetlessTransportPlan(
            processLaunchPlan: processLaunchPlan,
            timeout: timeout
        )
    }
}

/// Newly retained targetless transport. The adapter and coordinator share one epoch, while the
/// adapter's existing immutable instance binding supplies the frozen initial generation of one.
struct PersistentLLDBTargetlessTransport: Sendable {
    let epoch: DebuggerSessionEpoch
    let adapterGeneration: UInt64
    let timeout: Duration
    let adapter: PersistentLLDBCLIAdapter
    let coordinator: PersistentLLDBSessionCoordinator
    let preparer: PersistentLLDBProductionRequestPreparer
    /// The exact process-global authorities retained by the coordinator. A targetless transport
    /// constructed through the injectable seam may deliberately carry neither and therefore stays
    /// fail-closed for exact attach.
    let attachWriteInterlock: DebuggerLocalProcessAttachWriteInterlock?
    let localProcessEvidenceProvider: (any DebuggerLocalProcessEvidenceProviding)?
}

/// Bounded reason why construction could not publish a newly retained targetless transport after
/// its child adapter already existed. The retained adapter remains the sole ownership token when
/// command-free retirement cannot prove both child exit and reap.
enum PersistentLLDBTargetlessTransportConstructionFailure: Error, Equatable, Sendable {
    case cancelled
    case invalidInitialAdapterBinding

    var stableMessage: String {
        switch self {
        case .cancelled:
            "Targetless LLDB transport construction was cancelled."
        case .invalidInitialAdapterBinding:
            "Targetless LLDB transport did not establish its initial adapter binding."
        }
    }
}

/// Total post-acquisition ownership transfer. A pre-channel launcher failure may still throw;
/// after an adapter exists, construction either publishes the transport, proves command-free
/// child exit and reap before throwing, or returns the exact retained adapter for caller pinning.
enum PersistentLLDBTargetlessTransportConstructionOutcome: Sendable {
    case acquired(PersistentLLDBTargetlessTransport)
    case unresolved(
        failure: PersistentLLDBTargetlessTransportConstructionFailure,
        retainedAdapter: PersistentLLDBCLIAdapter
    )
}

/// One retained object must own both the byte stream and the exact child-process lifecycle.
/// Keeping those capabilities inseparable prevents a factory caller from pairing one channel with
/// a different process authority while still permitting deterministic no-write factory tests.
protocol PersistentLLDBTargetlessProcessChannel:
    AnyObject,
    PersistentLLDBCLIByteChannel,
    PersistentLLDBCLIRetainedProcess {}

extension FoundationPersistentLLDBCLIProcessChannel:
    PersistentLLDBTargetlessProcessChannel {}

/// Creates only the retained LLDB interpreter and its typed internal mechanics. It neither
/// advertises product attach capability nor admits an attach transaction; the controller must
/// still supply exact identity, lease, preflight, and sealed-transaction authority separately.
struct PersistentLLDBTargetlessTransportFactory: Sendable {
    typealias ProcessChannelLauncher = @MainActor @Sendable (
        PersistentLLDBCLIProcessLaunchPlan
    ) async throws -> any PersistentLLDBTargetlessProcessChannel

    private let processChannelLauncher: ProcessChannelLauncher
    private let attachWriteInterlock: DebuggerLocalProcessAttachWriteInterlock?
    private let localProcessEvidenceProvider:
        (any DebuggerLocalProcessEvidenceProviding)?
    /// Identity-only proof that production construction retained the app-global owned-process
    /// authority. The injectable test seam deliberately has no registry identity.
    let ownedInfrastructureRegistryIdentityForTesting: ObjectIdentifier?
    let attachWriteInterlockIdentityForTesting:
        DebuggerLocalProcessAttachWriteInterlockIdentity?
    let localProcessEvidenceProviderIsAvailableForTesting: Bool

    init(
        attachWriteInterlock: DebuggerLocalProcessAttachWriteInterlock? = nil,
        localProcessEvidenceProvider:
            (any DebuggerLocalProcessEvidenceProviding)? = nil,
        processChannelLauncher: @escaping ProcessChannelLauncher
    ) {
        self.processChannelLauncher = processChannelLauncher
        self.attachWriteInterlock = attachWriteInterlock
        self.localProcessEvidenceProvider = localProcessEvidenceProvider
        self.ownedInfrastructureRegistryIdentityForTesting = nil
        self.attachWriteInterlockIdentityForTesting = attachWriteInterlock?.identity
        self.localProcessEvidenceProviderIsAvailableForTesting =
            localProcessEvidenceProvider != nil
    }

    /// Production construction requires the app-global owned-process authority. The injectable
    /// closure initializer remains available only as an explicit test seam.
    init(
        ownedInfrastructureRegistry: DebuggerOwnedInfrastructureRegistry,
        localProcessEvidenceProvider: any DebuggerLocalProcessEvidenceProviding,
        processPreparer: @escaping PersistentLLDBOwnedProcessChannelLauncher.ProcessPreparer = {
            plan in
            try FoundationPersistentLLDBCLIProcessChannel.prepare(plan: plan)
        }
    ) {
        let launcher = PersistentLLDBOwnedProcessChannelLauncher(
            registry: ownedInfrastructureRegistry,
            processPreparer: processPreparer
        )
        self.processChannelLauncher = { processLaunchPlan in
            try await launcher.launch(plan: processLaunchPlan)
        }
        self.attachWriteInterlock = ownedInfrastructureRegistry.attachWriteInterlock
        self.localProcessEvidenceProvider = localProcessEvidenceProvider
        self.ownedInfrastructureRegistryIdentityForTesting = ObjectIdentifier(
            ownedInfrastructureRegistry
        )
        self.attachWriteInterlockIdentityForTesting =
            ownedInfrastructureRegistry.attachWriteInterlock.identity
        self.localProcessEvidenceProviderIsAvailableForTesting = true
    }

    @MainActor
    func make(
        plan: PersistentLLDBTargetlessTransportPlan,
        epoch: DebuggerSessionEpoch,
        inboundNeedleProbe: PersistentLLDBCLIInboundNeedleProbe? = nil
    ) async throws -> PersistentLLDBTargetlessTransportConstructionOutcome {
        try Task.checkCancellation()
        let channel = try await processChannelLauncher(plan.processLaunchPlan)
        let adapter = PersistentLLDBCLIAdapter(
            epoch: epoch,
            channel: channel,
            retainedProcess: channel,
            inboundNeedleProbe: inboundNeedleProbe
        )
        guard !Task.isCancelled else {
            return try await resolvePostAcquisitionFailure(
                .cancelled,
                retainedAdapter: adapter
            )
        }
        let adapterInstanceBinding = await adapter.adapterInstanceBinding()
        guard !Task.isCancelled else {
            return try await resolvePostAcquisitionFailure(
                .cancelled,
                retainedAdapter: adapter
            )
        }
        guard adapterInstanceBinding.sessionEpoch == epoch,
              adapterInstanceBinding.adapterGeneration == 1 else {
            return try await resolvePostAcquisitionFailure(
                .invalidInitialAdapterBinding,
                retainedAdapter: adapter
            )
        }
        let preparer = PersistentLLDBProductionRequestPreparer()
        let coordinator = PersistentLLDBSessionCoordinator(
            epoch: epoch,
            executor: adapter,
            requestPreparer: preparer,
            capabilities: .persistentCLIExactAttachInternal,
            launchedProcessEvidenceProvider: localProcessEvidenceProvider,
            attachWriteInterlock: attachWriteInterlock
        )
        let transport = PersistentLLDBTargetlessTransport(
            epoch: epoch,
            adapterGeneration: adapterInstanceBinding.adapterGeneration,
            timeout: plan.timeout,
            adapter: adapter,
            coordinator: coordinator,
            preparer: preparer,
            attachWriteInterlock: attachWriteInterlock,
            localProcessEvidenceProvider: localProcessEvidenceProvider
        )
        guard !Task.isCancelled else {
            return try await resolvePostAcquisitionFailure(
                .cancelled,
                retainedAdapter: adapter
            )
        }
        return .acquired(transport)
    }

    @MainActor
    private func resolvePostAcquisitionFailure(
        _ failure: PersistentLLDBTargetlessTransportConstructionFailure,
        retainedAdapter: PersistentLLDBCLIAdapter
    ) async throws -> PersistentLLDBTargetlessTransportConstructionOutcome {
        // Retained-process exit polling uses cancellable waits, so cleanup must run in a fresh task
        // rather than inheriting the failed construction task's cancellation state.
        let cleanup = Task.detached(priority: .userInitiated) {
            await retainedAdapter.retireRetainedAdapterWithoutDebuggerCommand()
        }
        let receipt = await cleanup.value
        guard !receipt.requestedGracefulQuit,
              receipt.didExit,
              receipt.didReap else {
            return .unresolved(
                failure: failure,
                retainedAdapter: retainedAdapter
            )
        }
        switch failure {
        case .cancelled:
            throw CancellationError()
        case .invalidInitialAdapterBinding:
            throw DebuggerClientError.backendFailure(failure.stableMessage)
        }
    }
}

extension DebuggerTransportCapabilities {
    /// Internal reducer mechanics for the sealed exact-attach lifecycle. This value is passed only
    /// to a targetless coordinator; it is never used by `DebuggerCapabilityReport` and therefore
    /// cannot enable product or UI attach advertisement.
    static var persistentCLIExactAttachInternal: DebuggerTransportCapabilities {
        var states = Dictionary(
            uniqueKeysWithValues: DebuggerOperation.allCases.map {
                ($0, DebuggerOperationCapability.supportedAndObserved)
            }
        )
        states[.launch] = .policyDenied(
            reason: "A targetless exact-attach transport cannot launch a process."
        )
        states[.terminate] = .policyDenied(
            reason: "Exact termination of an attached process is not implemented."
        )
        return DebuggerTransportCapabilities(
            operationStates: states,
            mechanics: .persistentCLI
        )
    }
}
