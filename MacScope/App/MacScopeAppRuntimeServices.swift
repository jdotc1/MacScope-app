import Dispatch
import Foundation

typealias ReconstructionJobSessionFactoryBuilder = @MainActor @Sendable (
    _ inferenceCoordinator: any ReconstructionReadyInferenceCoordinating
) -> ReconstructionJobSessionFactory

/// App-lifetime runtime services that must be shared by every document window.
///
/// This value is created exactly once by `MacScopeApp`. Copying the composition does not create a
/// second debugger authority graph because its actors have reference identity. Window roots receive
/// the retained graph explicitly through the SwiftUI environment; there is intentionally no
/// fallback graph.
struct MacScopeAppRuntimeServices: Sendable {
    static let productionShared: MacScopeAppRuntimeServices = {
        let nativeDecompilerRuntime = NativeDecompilerRuntimeRegistry.productionShared
        return MacScopeAppRuntimeServices(
            debuggerRuntimeAuthorities: DebuggerRuntimeAuthorities(),
            nativeDecompilerRuntime: nativeDecompilerRuntime,
            reconstructionJobSessionFactoryBuilderResolver: {
                ReconstructionProductionComposition.jobSessionFactoryBuilder(
                    nativeDecompilerRuntime: nativeDecompilerRuntime
                )
            }
        )
    }()

    let debuggerRuntimeAuthorities: DebuggerRuntimeAuthorities
    let nativeDecompilerRuntime: NativeDecompilerRuntimeRegistry
    let nativeDecompilerMemoryPressureMonitor: NativeDecompilerMemoryPressureMonitor
    /// Copies retain this exact task, including its rejected result. Security's synchronous
    /// bundle/provenance validation never runs in the app's main-actor initializer.
    private let reconstructionJobSessionFactoryBuilderTask:
        Task<ReconstructionJobSessionFactoryBuilder?, Never>

    private init(
        debuggerRuntimeAuthorities: DebuggerRuntimeAuthorities =
            DebuggerRuntimeAuthorities(),
        nativeDecompilerRuntime: NativeDecompilerRuntimeRegistry,
        reconstructionJobSessionFactoryBuilderResolver:
            @escaping @Sendable () -> ReconstructionJobSessionFactoryBuilder?
    ) {
        self.debuggerRuntimeAuthorities = debuggerRuntimeAuthorities
        self.nativeDecompilerRuntime = nativeDecompilerRuntime
        nativeDecompilerMemoryPressureMonitor = NativeDecompilerMemoryPressureMonitor(
            runtime: nativeDecompilerRuntime
        )
        reconstructionJobSessionFactoryBuilderTask = Task.detached(priority: .utility) {
            reconstructionJobSessionFactoryBuilderResolver()
        }
    }

    /// Internal composition seam used by tests. External product code can obtain only
    /// `productionShared`; no caller outside the MacScope module can access this function.
    static func testing(
        debuggerRuntimeAuthorities: DebuggerRuntimeAuthorities,
        nativeDecompilerRuntime: NativeDecompilerRuntimeRegistry,
        reconstructionJobSessionFactoryBuilder:
            ReconstructionJobSessionFactoryBuilder? = nil
    ) -> MacScopeAppRuntimeServices {
        MacScopeAppRuntimeServices(
            debuggerRuntimeAuthorities: debuggerRuntimeAuthorities,
            nativeDecompilerRuntime: nativeDecompilerRuntime,
            reconstructionJobSessionFactoryBuilderResolver: {
                reconstructionJobSessionFactoryBuilder
            }
        )
    }

    /// Exercises the production detached-resolution boundary without admitting unsigned
    /// provenance or replacing any Security policy in the production validator.
    static func testing(
        debuggerRuntimeAuthorities: DebuggerRuntimeAuthorities,
        nativeDecompilerRuntime: NativeDecompilerRuntimeRegistry,
        reconstructionJobSessionFactoryBuilderResolver:
            @escaping @Sendable () -> ReconstructionJobSessionFactoryBuilder?
    ) -> MacScopeAppRuntimeServices {
        MacScopeAppRuntimeServices(
            debuggerRuntimeAuthorities: debuggerRuntimeAuthorities,
            nativeDecompilerRuntime: nativeDecompilerRuntime,
            reconstructionJobSessionFactoryBuilderResolver:
                reconstructionJobSessionFactoryBuilderResolver
        )
    }

    func shutdown() async {
        reconstructionJobSessionFactoryBuilderTask.cancel()
        await nativeDecompilerRuntime.shutdown()
    }

    /// Returns nil unless the production graph was created from the signed app's canonical,
    /// Release-eligible provenance resource. This is the fail-closed activation boundary: Debug
    /// and malformed/re-signed bundles can still present the destination, but receive no commands
    /// backed by fabricated producer identity. The builder receives the exact single app-owned
    /// inference coordinator and retains that identity in every job planner.
    @MainActor
    func reconstructionWorkspaceRuntimeFactory(
        inferenceCoordinator: any ReconstructionReadyInferenceCoordinating
    ) async -> ReconstructionWorkspaceRuntimeFactory? {
        guard !Task.isCancelled,
              !reconstructionJobSessionFactoryBuilderTask.isCancelled else { return nil }
        let resolvedBuilder = await reconstructionJobSessionFactoryBuilderTask.value
        guard !Task.isCancelled,
              !reconstructionJobSessionFactoryBuilderTask.isCancelled,
              let reconstructionJobSessionFactoryBuilder = resolvedBuilder else { return nil }
        let makeJobSession = reconstructionJobSessionFactoryBuilder(inferenceCoordinator)
        let openDatabase: ReconstructionWorkspaceDatabaseRuntimeFactory = {
            binding,
            packageState,
            packageSources,
            workspaceName in
            try await Task.detached(priority: .utility) {
                try ReconstructionWorkspaceDatabaseRuntime.open(
                    binding: binding,
                    packageState: packageState,
                    packageAttachmentSources: packageSources,
                    workspaceName: workspaceName
                )
            }.value
        }
        return { windowID, store, documentSession, predecessorRetirement in
            ReconstructionWorkspaceRuntime(
                windowID: windowID,
                store: store,
                documentSession: documentSession,
                predecessorRetirement: predecessorRetirement,
                openDatabaseRuntime: openDatabase,
                makeJobSession: makeJobSession
            )
        }
    }

    func reconstructionNativeDecompilerAdmissionFactory(
        durable: any ReconstructionNativeDecompilerDurableJobValidating
    ) -> ReconstructionNativeDecompilerAdmissionFactory {
        ReconstructionNativeDecompilerAdmissionFactory(
            runtime: nativeDecompilerRuntime,
            durable: durable
        )
    }

    /// Builds the headless Reconstruction execution graph around the one app-owned native
    /// runtime. The durable job ID becomes the fairness owner; task/checkpoint identities remain
    /// publication fences and can never mint a parallel client, process runtime, or execution lane.
    func reconstructionBatchScheduler(
        durableJobID: UUID,
        durable: any ReconstructionNativeDecompilerDurableJobValidating,
        resolver: any ReconstructionHeadlessAnalysisRequestResolving,
        providerFactory: any ReconstructionAnalysisProviderFactory =
            ReconstructionDefaultAnalysisProviderFactory(),
        analysisBudget: ReconstructionAnalysisProviderPoolBudget
    ) async throws -> ReconstructionBatchScheduler {
        let admission = try await reconstructionNativeDecompilerAdmissionFactory(
            durable: durable
        ).admission(forDurableJobID: durableJobID)
        do {
            return try reconstructionBatchScheduler(
                durableJobID: durableJobID,
                native: ReconstructionNativeDecompilerAdapter(admission: admission),
                resolver: resolver,
                providerFactory: providerFactory,
                analysisBudget: analysisBudget
            )
        } catch {
            await admission.retire()
            throw error
        }
    }

    /// Builds the retained execution graph around an admission already minted for this exact
    /// durable job. Production workspace composition uses this overload so evolving committed
    /// cuts can never mint a second native owner while rebuilding lightweight request state.
    func reconstructionBatchScheduler(
        durableJobID: UUID,
        admission: any NativeDecompilerOwnerAdmission,
        resolver: any ReconstructionHeadlessAnalysisRequestResolving,
        providerFactory: any ReconstructionAnalysisProviderFactory =
            ReconstructionDefaultAnalysisProviderFactory(),
        analysisBudget: ReconstructionAnalysisProviderPoolBudget
    ) throws -> ReconstructionBatchScheduler {
        try reconstructionBatchScheduler(
            durableJobID: durableJobID,
            native: ReconstructionNativeDecompilerAdapter(admission: admission),
            resolver: resolver,
            providerFactory: providerFactory,
            analysisBudget: analysisBudget
        )
    }

    /// Builds a cut-local scheduler around the one job-owned native adapter. The production
    /// execution controller pauses and replaces these lightweight schedulers as committed cuts
    /// advance, while the adapter/admission remains live until final job-session retirement.
    func reconstructionBatchScheduler(
        durableJobID: UUID,
        native: any ReconstructionNativeTaskDecompiling,
        resolver: any ReconstructionHeadlessAnalysisRequestResolving,
        providerFactory: any ReconstructionAnalysisProviderFactory =
            ReconstructionDefaultAnalysisProviderFactory(),
        analysisBudget: ReconstructionAnalysisProviderPoolBudget
    ) throws -> ReconstructionBatchScheduler {
        let pool = try ReconstructionAnalysisProviderPool(
            factory: providerFactory,
            budget: analysisBudget
        )
        let executor = ReconstructionBatchTaskExecutor(
            resolver: resolver,
            headless: ReconstructionHeadlessAnalysisExecutor(pool: pool),
            native: native
        )
        return ReconstructionBatchScheduler(
            durableJobID: durableJobID,
            executor: executor
        )
    }
}

enum NativeDecompilerMemoryPressureLevel: Equatable, Sendable {
    case warning
    case critical
}

/// App-lifetime memory-pressure bridge for the native process generation.
///
/// Warning pressure trims validated successes to the bounded warm set; critical pressure clears
/// them. Neither event invents a process transition or disturbs active waiter ownership.
final class NativeDecompilerMemoryPressureMonitor: @unchecked Sendable {
    private let source: any DispatchSourceMemoryPressure

    init(runtime: NativeDecompilerRuntimeRegistry) {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue(
                label: "org.macscope.MacScope.NativeDecompiler.MemoryPressure",
                qos: .utility
            )
        )
        self.source = source
        source.setEventHandler { [weak runtime, weak source] in
            guard let source else { return }
            let level: NativeDecompilerMemoryPressureLevel =
                source.data.contains(.critical) ? .critical : .warning
            Task { await runtime?.memoryPressureDidOccur(level) }
        }
        source.activate()
    }

    deinit {
        source.setEventHandler(handler: nil)
        source.cancel()
    }
}

/// Exactly-once async barrier used by AppKit's deferred termination reply.
///
/// The actor retains the first shutdown task so duplicate termination requests await the same
/// app-owned drain instead of starting competing shutdown sequences.
actor MacScopeAppTerminationCoordinator {
    typealias Shutdown = @Sendable () async -> Void

    private let shutdown: Shutdown
    private var shutdownTask: Task<Void, Never>?

    init(shutdown: @escaping Shutdown) {
        self.shutdown = shutdown
    }

    func terminate() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let shutdown = self.shutdown
        let task = Task { await shutdown() }
        shutdownTask = task
        await task.value
    }
}
