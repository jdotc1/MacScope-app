import Darwin
import Foundation

struct LocalLLDBDebuggerClient: DebuggerClient {
    func shutdown() async { await adapter.shutdown() }
    let capabilities: DebuggerCapabilityReport
    private let adapter: any LLDBDebuggerBackendAdapter
    /// Retains the complete app-global authority graph as one identity-preserving composition.
    /// Injected adapters and isolated/default clients deliberately retain no authority graph.
    private let debuggerRuntimeAuthorities: DebuggerRuntimeAuthorities?

    init() {
        self.init(adapter: XcodeLLDBCommandLineAdapter())
    }

    /// Production construction seam for the one app-global debugger authority graph. The exact
    /// lease actor, owned-process actor, and policy provider reach the persistent controller while
    /// the client retains the whole graph as their app-lifetime composition owner.
    init(debuggerRuntimeAuthorities: DebuggerRuntimeAuthorities) {
        self.init(
            debuggerRuntimeAuthorities: debuggerRuntimeAuthorities,
            inboundNeedleProbe: nil
        )
    }

    /// Opt-in signed-smoke seam. The probe observes only the persistent transport's inbound bytes;
    /// the client still retains and injects the same complete app-global authority graph used by
    /// normal production construction.
    init(
        debuggerRuntimeAuthorities: DebuggerRuntimeAuthorities,
        inboundNeedleProbe: PersistentLLDBCLIInboundNeedleProbe?
    ) {
        let adapter = XcodeLLDBCommandLineAdapter(
            debuggerSessionLeaseRegistry:
                debuggerRuntimeAuthorities.sessionLeaseRegistry,
            ownedInfrastructureRegistry:
                debuggerRuntimeAuthorities.ownedInfrastructureRegistry,
            observationPolicyProvider:
                debuggerRuntimeAuthorities.observationPolicyProvider,
            inboundNeedleProbe: inboundNeedleProbe
        )
        self.adapter = adapter
        self.capabilities = adapter.capabilities
        self.debuggerRuntimeAuthorities = debuggerRuntimeAuthorities
    }

    init(adapter: any LLDBDebuggerBackendAdapter) {
        self.adapter = adapter
        self.capabilities = adapter.capabilities
        self.debuggerRuntimeAuthorities = nil
    }

    var sessionLeaseAuthorityForTesting: PersistentLLDBSessionLeaseAuthorityProjection? {
        (adapter as? XcodeLLDBCommandLineAdapter)?.sessionLeaseAuthorityForTesting
    }

    var runtimeAuthoritiesForTesting: DebuggerRuntimeAuthorities? {
        debuggerRuntimeAuthorities
    }

    var persistentRuntimeAuthorityProjectionForTesting:
        PersistentLLDBRuntimeAuthorityProjection? {
        (adapter as? XcodeLLDBCommandLineAdapter)?
            .persistentRuntimeAuthorityProjectionForTesting
    }

    func observationPolicySnapshotForTesting() async
        -> DebuggerLocalProcessResolution<DebuggerLocalProcessObservationPolicySnapshot>?
    {
        await (adapter as? XcodeLLDBCommandLineAdapter)?
            .observationPolicySnapshotForTesting()
    }

    func makeInitialSnapshot() -> DebuggerSessionSnapshot {
        var snapshot = DebuggerSessionSnapshot.empty
        snapshot.backendState = adapter.initialBackendState
        snapshot.statusMessage = capabilities.summary
        return snapshot
    }

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot {
        guard capabilities.launchSupport.isSupported else {
            throw unavailable("Cannot launch \(configuration.displayName): \(capabilities.launchSupport.unavailableReason ?? capabilities.summary)")
        }

        return try await adapter.launch(configuration)
    }

    func attach(
        _ request: DebuggerLocalAttachRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        guard capabilities.attachSupport.isSupported else {
            throw unavailable(
                "Cannot attach to pid \(request.selectedIdentity.processID): \(capabilities.attachSupport.unavailableReason ?? capabilities.summary)"
            )
        }

        guard snapshot.processState.canLaunchNewProcess else {
            throw DebuggerClientError.invalidState(
                "Cannot attach while the debugger is \(snapshot.processState.displayTitle.lowercased())."
            )
        }

        return try await adapter.attach(request, from: snapshot)
    }

    func attach(toPID request: DebuggerAttachPIDRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        _ = request
        _ = snapshot
        throw DebuggerClientError.unsupportedOperation(
            "Raw PID attach is disabled; select and authorize an exactly identified local process."
        )
    }

    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard capabilities.executionControlSupport.isSupported else {
            throw unavailable("Continue is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
        }

        guard snapshot.canContinueLiveProcess else {
            throw DebuggerClientError.invalidState("Continue requires a paused live debug process.")
        }

        return try await adapter.continueExecution(from: snapshot)
    }

    func runToCursor(_ request: DebuggerRunToCursorRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard capabilities.executionControlSupport.isSupported else {
            throw unavailable("Run to cursor is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
        }

        guard snapshot.canRunToCursorLiveProcess else {
            throw DebuggerClientError.invalidState("Run to cursor requires a paused live debug process.")
        }

        return try await adapter.runToCursor(request, from: snapshot)
    }

    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard capabilities.executionControlSupport.isSupported else {
            throw unavailable("Step over is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
        }

        guard snapshot.canStepOverLiveProcess else {
            throw DebuggerClientError.invalidState("Step over requires a paused live debug process.")
        }

        return try await adapter.stepOver(from: snapshot)
    }

    func stepInto(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard capabilities.executionControlSupport.isSupported else {
            throw unavailable("Step into is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
        }

        guard snapshot.canStepIntoLiveProcess else {
            throw DebuggerClientError.invalidState("Step into requires a paused live debug process.")
        }

        return try await adapter.stepInto(from: snapshot)
    }

    func stepOut(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard capabilities.executionControlSupport.isSupported else {
            throw unavailable("Step out is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
        }

        guard snapshot.canStepOutLiveProcess else {
            throw DebuggerClientError.invalidState("Step out requires a paused live debug process.")
        }

        return try await adapter.stepOut(from: snapshot)
    }

    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard capabilities.executionControlSupport.isSupported else {
            throw unavailable("Pause is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
        }

        guard snapshot.canPauseLiveProcess else {
            throw DebuggerClientError.invalidState("Pause requires a running live debug process.")
        }

        return try await adapter.pause(from: snapshot)
    }

    func detach(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard capabilities.executionControlSupport.isSupported else {
            throw unavailable("Detach is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
        }

        guard snapshot.canDetachLiveProcess else {
            throw DebuggerClientError.invalidState("Detach requires an attached live debug process.")
        }

        return try await adapter.detach(from: snapshot)
    }

    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard capabilities.executionControlSupport.isSupported else {
            throw unavailable("Terminate is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
        }

        guard snapshot.canTerminateLiveProcess else {
            throw DebuggerClientError.invalidState("Terminate requires a live debug process.")
        }

        return try await adapter.terminate(from: snapshot)
    }

    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard capabilities.executionControlSupport.isSupported else {
            throw unavailable("Breakpoint mutation is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
        }

        guard snapshot.hasLiveProcessSession else {
            throw DebuggerClientError.invalidState("Breakpoint mutation requires a live debug process.")
        }

        return try await adapter.replaceBreakpoints(breakpoints, from: snapshot)
    }

    func reconcileLogicalBreakpoints(
        _ request: DebuggerLogicalBreakpointReconcileRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        guard snapshot.transportBreakpointBindingState != nil else {
            throw DebuggerClientError.invalidState(
                "Typed logical-breakpoint resolution requires a persistent live debugger session."
            )
        }
        return try await adapter.reconcileLogicalBreakpoints(
            request,
            from: snapshot
        )
    }

    func writeRegister(_ request: DebuggerRegisterWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard capabilities.executionControlSupport.isSupported else {
            throw unavailable("Register write is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
        }

        guard snapshot.canWriteRegisterLiveProcess else {
            throw DebuggerClientError.invalidState("Register write requires a paused live debug process.")
        }

        return try await adapter.writeRegister(request, from: snapshot)
    }

    func readMemory(_ request: DebuggerMemoryReadRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard capabilities.executionControlSupport.isSupported else {
            throw unavailable("Memory read is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
        }

        guard snapshot.canReadMemoryLiveProcess else {
            throw DebuggerClientError.invalidState("Memory read requires a paused live debug process.")
        }

        return try await adapter.readMemory(request, from: snapshot)
    }

    func updateWatchpoints(_ request: DebuggerWatchpointRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard capabilities.executionControlSupport.isSupported, snapshot.canWriteMemoryLiveProcess else {
            throw DebuggerClientError.invalidState("Watchpoints require a paused live debug process.")
        }
        return try await adapter.updateWatchpoints(request, from: snapshot)
    }

    func writeMemory(_ request: DebuggerMemoryWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard capabilities.executionControlSupport.isSupported else {
            throw unavailable("Memory write is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
        }

        guard snapshot.canWriteMemoryLiveProcess else {
            throw DebuggerClientError.invalidState("Memory write requires a paused live debug process.")
        }

        return try await adapter.writeMemory(request, from: snapshot)
    }

    func evaluateExpression(_ request: DebuggerExpressionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerExpressionResult {
        guard capabilities.executionControlSupport.isSupported else {
            throw unavailable("Expression evaluation is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
        }

        guard snapshot.canEvaluateExpressionLiveProcess else {
            throw DebuggerClientError.invalidState("Expression evaluation requires a paused live debug process.")
        }

        return try await adapter.evaluateExpression(request, from: snapshot)
    }

    func expandVariableChildren(
        _ request: DebuggerVariableExpansionRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        guard capabilities.executionControlSupport.isSupported else {
            throw unavailable(
                "Variable child expansion is unavailable: "
                    + (capabilities.executionControlSupport.unavailableReason
                        ?? capabilities.summary)
            )
        }
        guard snapshot.canRefreshStoppedSnapshot else {
            throw DebuggerClientError.invalidState(
                "Variable child expansion requires a paused live debug process."
            )
        }
        return try await adapter.expandVariableChildren(request, from: snapshot)
    }

    func selectThread(_ request: DebuggerThreadSelectionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard capabilities.executionControlSupport.isSupported else {
            throw unavailable("Thread selection is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
        }

        guard snapshot.canSelectThreadLiveProcess else {
            throw DebuggerClientError.invalidState("Thread selection requires a paused live debug process.")
        }

        return try await adapter.selectThread(request, from: snapshot)
    }

    func selectFrame(_ request: DebuggerFrameSelectionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard capabilities.executionControlSupport.isSupported else {
            throw unavailable("Frame selection is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
        }

        guard snapshot.canSelectFrameLiveProcess else {
            throw DebuggerClientError.invalidState("Frame selection requires a paused live debug process.")
        }

        return try await adapter.selectFrame(request, from: snapshot)
    }

    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard capabilities.executionControlSupport.isSupported else {
            throw unavailable("Snapshot refresh is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
        }

        guard snapshot.canRefreshStoppedSnapshot else {
            throw DebuggerClientError.invalidState("Snapshot refresh requires a paused live debug process.")
        }

        return try await adapter.refreshSnapshot(from: snapshot)
    }

    func pollProcessStatus(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        guard capabilities.executionControlSupport.isSupported else {
            throw unavailable("Process-status observation is unavailable: \(capabilities.executionControlSupport.unavailableReason ?? capabilities.summary)")
        }

        guard snapshot.processState.isRunning else {
            throw DebuggerClientError.invalidState("Process-status observation requires a running live debug process.")
        }

        return try await adapter.pollProcessStatus(from: snapshot)
    }

    private func unavailable(_ reason: String) -> DebuggerClientError {
        .backendUnavailable(reason)
    }
}
