import Foundation

/// Chooses the analysis provider for a GUI workspace behind the `AnalysisProviding` seam.
///
/// Default is the OUT-OF-PROCESS XPC worker (crash isolation: a decoder/parser fault in a hostile
/// binary takes down the worker, not the app — the client observes `workerCrashed` and the next
/// analysis relaunches a fresh worker). An escape hatch forces the in-process engine, so a build
/// without the embedded `.xpc`, a headless diagnostic, or a regression can fall back without code
/// changes.
///
/// This is a CLIENT-side factory (it constructs `NSXPCConnectionTransport`); it lives in the app
/// target only. The worker service target lists its sources explicitly and never compiles this.
enum AnalysisProviderFactory {
    /// The out-of-process worker is the default. `--macscope-in-process-analysis` (argv) or
    /// `MACSCOPE_IN_PROCESS_ANALYSIS=1` (env) forces the in-process engine. Tests and headless
    /// launchers never call this — they pass an explicit provider — so this decision is scoped to
    /// real GUI windows.
    static func usesOutOfProcessAnalysis(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if arguments.contains("--macscope-in-process-analysis") { return false }
        if environment["MACSCOPE_IN_PROCESS_ANALYSIS"] == "1" { return false }
        // Under XCTest the bundle loads into the app as its TEST_HOST, so a bootstrap store built
        // by a test would otherwise launch the real `.xpc`. Keep tests hermetic and in-process —
        // the XPC path is exercised by its own unit suites (with a mock transport) and by GUI
        // acceptance, never as an implicit side effect of `bootstrap()` in an unrelated test.
        if NSClassFromString("XCTestCase") != nil { return false }
        return true
    }

    /// The provider a freshly bootstrapped GUI window analyzes through.
    static func makeDefault(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resourceBudget: AnalysisResourceBudget? = nil
    ) -> any AnalysisProviding {
        guard usesOutOfProcessAnalysis(arguments: arguments, environment: environment) else {
            if let resourceBudget {
                return ResourceBudgetedAnalysisProvider(provider: AnalysisEngine(), budget: resourceBudget)
            }
            return AnalysisEngine()
        }
        // The transport establishes the connection lazily — the `.xpc` worker process is not
        // launched until the first `analyze` message, so an empty "No binary open" window pays
        // nothing. `XPCAnalysisProvider` owns the reconnect-on-crash state machine.
        return XPCAnalysisProvider(
            transport: NSXPCConnectionTransport(),
            codec: PayloadWireCodec(),
            resourceBudget: resourceBudget
        )
    }

    /// The app-owned supplemental dyld-cache workflow. This is deliberately separate from
    /// `makeDefault()`: the ordinary `AnalysisProviding` result remains authoritative for loaded
    /// bytes, addresses, and workspace state, while MachOKit contributes only a typed differential
    /// report through the signed analysis worker.
    static func makeDefaultDyldCacheDifferentialWorkflow()
        -> DyldCacheDifferentialWorkflowCoordinator
    {
        makeDyldCacheDifferentialWorkflow(
            transport: NSXPCConnectionTransport(),
            codec: DyldCacheAnalysisWireCodec()
        )
    }

    /// Constructs the same signed-XPC client used by product composition while permitting a
    /// deterministic transport and request-ID source in focused qualification.
    static func makeDyldCacheDifferentialWorkflow(
        transport: any DyldCacheAnalysisTransport,
        codec: any DyldCacheAnalysisClientWireCodec,
        makeRequestID: @escaping @Sendable () -> UUID = UUID.init
    ) -> DyldCacheDifferentialWorkflowCoordinator {
        makeDyldCacheDifferentialWorkflow(
            provider: XPCDyldCacheAnalysisProvider(
                transport: transport,
                codec: codec,
                makeRequestID: makeRequestID
            )
        )
    }

    /// Injection seam used by focused tests and headless qualification. Product composition uses
    /// `makeDefaultDyldCacheDifferentialWorkflow()` above, so both paths exercise the same app-owned
    /// generation, identity, stale-result, and differential-publication logic.
    static func makeDyldCacheDifferentialWorkflow(
        provider: any DyldCacheAnalysisProviding
    ) -> DyldCacheDifferentialWorkflowCoordinator {
        DyldCacheDifferentialWorkflowCoordinator(provider: provider)
    }
}
