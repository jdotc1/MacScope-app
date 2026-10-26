import Foundation

/// Pure compatibility projection from the authoritative WS-19 reducer state into the existing UI
/// snapshot model. The projection is intentionally one-way: no reducer transition accepts a
/// `DebuggerSessionSnapshot` as input authority.
enum DebuggerTransportSnapshotProjector {
    static func project(
        _ state: DebuggerReducerState,
        adapterName: String = "Xcode LLDB CLI",
        executableName: String? = nil,
        runtimeMappingProjection: DebuggerRuntimeMappingProjection? = nil
    ) -> DebuggerSessionSnapshot {
        let presentedAdapterName = nonempty(adapterName) ?? "Xcode LLDB CLI"
        let processState = projectProcessState(state, executableName: executableName)
        let backendState = projectBackendState(
            state,
            adapterName: presentedAdapterName,
            processState: processState
        )
        let stoppedData = projectStoppedData(state)
        let statusMessage = projectStatusMessage(
            state,
            processState: processState
        )

        return DebuggerSessionSnapshot(
            processState: processState,
            breakpoints: state.breakpoints.map(projectBreakpoint),
            threads: stoppedData.threads,
            frames: stoppedData.frames,
            registers: stoppedData.registers,
            memoryRegions: stoppedData.memoryRegions,
            variableScopes: stoppedData.variableScopes,
            statusMessage: statusMessage,
            backendState: backendState,
            lastCommandRun: nil,
            transportSessionCoordinate: state.sessionCoordinate,
            transportStopCoordinate: state.stopCoordinate,
            transportEventSequence: state.lastAcceptedEventSequence,
            transportDiagnostic: state.stoppedData?.threadIdentityDiagnostic.map {
                DebuggerDiagnostic.make(
                    code: .protocolViolation,
                    severity: .error,
                    rawText: $0,
                    targetDisposition: state.targetDisposition
                )
            } ?? state.lastDiagnostic,
            transportTargetDisposition: state.targetDisposition,
            transportTargetAuthority: state.acceptedTargetAuthority,
            transportRuntimeModuleAuthorityRevision:
                state.runtimeModuleInventoryState.authorityRevision,
            transportRuntimeModuleAuthority: state.runtimeModuleInventoryState.authority,
            transportBreakpointBindingAuthorityRevision:
                state.breakpointBindingState.authorityRevision,
            transportBreakpointBindingState: state.breakpointBindingState,
            runtimeMappingProjection: runtimeMappingProjection,
            watchpoints: state.watchpoints,
            watchpointError: state.watchpointError
        )
    }

    private static func projectProcessState(
        _ state: DebuggerReducerState,
        executableName: String?
    ) -> DebuggerProcessState {
        switch state.processPhase {
        case .noTarget:
            if let pending = state.pendingRequest,
               pending.context.operation.classification == .sessionEstablishing {
                let target = nonempty(executableName) ?? pending.context.operation.displayLabel
                return .launching(targetPath: target)
            }
            return .notAttached

        case .running(let processID):
            return .running(
                processID: processID,
                executableName: nonempty(executableName) ?? "pid \(processID)"
            )

        case .stopped(let processID, let reason):
            return .paused(processID: processID, reason: projectPauseReason(reason))

        case .detaching(let processID):
            return .detaching(processID: processID)

        case .exited(_, let code):
            return .exited(code: code)

        case .detached, .terminated:
            return .notAttached

        case .invalidated:
            return .unavailable(reason: invalidationMessage(state))
        }
    }

    private static func projectBackendState(
        _ state: DebuggerReducerState,
        adapterName: String,
        processState: DebuggerProcessState
    ) -> DebuggerBackendSessionState {
        switch state.processPhase {
        case .noTarget:
            if case .launching(let targetPath) = processState {
                return .launching(targetPath: targetPath)
            }
            return .ready(adapterName: adapterName)
        case .running(let processID), .stopped(let processID, _):
            return .connected(processID: processID, adapterName: adapterName)
        case .detaching(let processID):
            return .disconnecting(processID: processID, adapterName: adapterName)
        case .exited, .detached, .terminated:
            return .ready(adapterName: adapterName)
        case .invalidated:
            return .failed(reason: invalidationMessage(state))
        }
    }

    private static func projectStoppedData(
        _ state: DebuggerReducerState
    ) -> (
        threads: [DebuggerThreadSummary],
        frames: [DebuggerFrameSummary],
        registers: [DebuggerRegisterSummary],
        memoryRegions: [DebuggerMemorySummary],
        variableScopes: [DebuggerVariableScopeSnapshot]
    ) {
        guard case .stopped = state.processPhase,
              let data = state.stoppedData else {
            return ([], [], [], [], [])
        }

        let threads: [DebuggerThreadSummary]
        switch data.threads {
        case .available(let values):
            threads = values.map { value in
                DebuggerThreadSummary(
                    tid: value.threadID,
                    index: value.identifier,
                    queueName: value.queueName,
                    stopReason: value.stopReason.map(projectPauseReason),
                    isSelected: data.selectedThreadID == value.identifier || value.isSelected,
                    topFrameAddress: value.topFrameAddress,
                    topFrameFunctionName: value.topFrameFunctionName,
                    name: value.name
                )
            }
        case .unavailable:
            threads = []
        }

        let frames: [DebuggerFrameSummary]
        switch data.frames {
        case .available(let values):
            frames = values.map { value in
                DebuggerFrameSummary(
                    index: value.identifier,
                    address: value.address,
                    functionName: value.functionName,
                    moduleName: value.moduleName,
                    sourceLocation: value.sourceLocation
                )
            }
        case .unavailable:
            frames = []
        }

        let registers: [DebuggerRegisterSummary]
        switch data.registers {
        case .available(let values):
            registers = values.map { value in
                DebuggerRegisterSummary(
                    name: value.name,
                    value: value.value,
                    role: value.role,
                    group: projectRegisterGroup(value.group)
                )
            }
        case .unavailable:
            registers = []
        }

        let memoryRegions: [DebuggerMemorySummary]
        switch data.memoryPreviews {
        case .available(let values):
            memoryRegions = values.map { value in
                DebuggerMemorySummary(
                    address: value.address,
                    byteCount: value.bytes.count,
                    previewBytes: value.bytes,
                    label: value.label
                )
            }
        case .unavailable:
            memoryRegions = []
        }

        let variableScopes: [DebuggerVariableScopeSnapshot]
        switch data.variables {
        case .available(let values):
            variableScopes = values.map {
                DebuggerVariableScopeSnapshot(
                    coordinate: $0.coordinate,
                    scope: $0.scope,
                    nodes: $0.nodes,
                    wasTruncated: $0.wasTruncated
                )
            }
        case .unavailable:
            variableScopes = []
        }

        return (threads, frames, registers, memoryRegions, variableScopes)
    }

    private static func projectBreakpoint(
        _ breakpoint: DebuggerTransportBreakpoint
    ) -> DebuggerBreakpoint {
        DebuggerBreakpoint(
            address: breakpoint.address,
            isEnabled: breakpoint.isEnabled,
            condition: breakpoint.condition,
            hitCount: breakpoint.hitCount,
            ignoreCount: breakpoint.ignoreCount
        )
    }

    private static func projectPauseReason(
        _ reason: DebuggerTransportStopReason
    ) -> DebuggerPauseReason {
        switch reason {
        case .breakpoint(let address):
            .breakpoint(address: address)
        case .step:
            .step
        case .signal(let signal):
            .signal(signal)
        case .userRequested:
            .userRequested
        case .unknown(let detail):
            .unknown(detail)
        }
    }

    private static func projectRegisterGroup(
        _ group: DebuggerStoppedRegisterGroup
    ) -> DebuggerRegisterGroup {
        switch group {
        case .generalPurpose: .generalPurpose
        case .floatingPoint: .floatingPoint
        case .system: .system
        case .other: .other
        }
    }

    private static func projectStatusMessage(
        _ state: DebuggerReducerState,
        processState: DebuggerProcessState
    ) -> String {
        let diagnosticSuffix: String
        if let diagnostic = state.lastDiagnostic {
            diagnosticSuffix = diagnostic.preview.isEmpty
                ? " \(diagnostic.semanticLabel)."
                : " \(diagnostic.semanticLabel): \(diagnostic.preview)"
        } else {
            diagnosticSuffix = ""
        }
        switch state.processPhase {
        case .noTarget:
            if let pending = state.pendingRequest {
                return "\(pending.context.operation.displayLabel)…"
            }
            return "Debugger backend is ready."
        case .running:
            return processState.detail + diagnosticSuffix
        case .stopped:
            return processState.detail + diagnosticSuffix
        case .detaching:
            return processState.detail + diagnosticSuffix
        case .exited:
            return processState.detail + diagnosticSuffix
        case .detached(let processID):
            return "Detached from pid \(processID)." + diagnosticSuffix
        case .terminated(let processID):
            return "Terminated pid \(processID)." + diagnosticSuffix
        case .invalidated:
            return invalidationMessage(state)
        }
    }

    private static func invalidationMessage(_ state: DebuggerReducerState) -> String {
        guard let diagnostic = state.lastDiagnostic else {
            return "Debugger session invalidated; target disposition is unknown."
        }
        guard !diagnostic.preview.isEmpty else {
            return diagnostic.semanticLabel
        }
        return "\(diagnostic.semanticLabel): \(diagnostic.preview)"
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
