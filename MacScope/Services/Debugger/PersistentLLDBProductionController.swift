import CryptoKit
import Foundation

enum PersistentLLDBProductionControllerError: Error {
    case missingPreparedOperation
    case unusableStoppedData
    case unusableExpressionResult
    case unusableLogicalBreakpointAuthority
    case unusableRunToCursorAuthority
    case variableExtractorInstallationTimedOut
}

/// Total ownership transfer for one injected production LLDB spawn attempt. Every outcome carries
/// the exact retained channel, so the test seam cannot represent a post-spawn throw that discards
/// child ownership. Only the controller's concrete Foundation launcher may report a pre-child
/// throw, at the call site where its configure/run ordering is known.
enum PersistentLLDBProductionProcessChannelLaunchOutcome: Sendable {
    case acquired(any PersistentLLDBTargetlessProcessChannel)
    case failedAfterChild(
        channel: any PersistentLLDBTargetlessProcessChannel,
        reason: String
    )
}

enum PersistentLLDBLogicalBreakpointControllerRecovery: Equatable, Sendable {
    case none
    case boundedTargetRecovery
    case invalidateSessionAndShutdownAdapter
}

enum PersistentLLDBExactLaunchAdapterRetirementPolicy: Equatable, Sendable {
    case retainedAdapterOnly
}

enum PersistentLLDBExactAttachedExternalExitSettlementOutcome: Equatable, Sendable {
    case released
    case unresolved
}

struct PersistentLLDBSessionLeaseAuthorityProjection: Equatable {
    let registryIdentity: ObjectIdentifier?
    let ownerID: DebuggerSessionLeaseOwnerID

    var isAvailable: Bool {
        registryIdentity != nil
    }
}

struct PersistentLLDBRuntimeAuthorityProjection: Equatable {
    let sessionLeaseRegistryIdentity: ObjectIdentifier?
    let sessionLeaseInterlockIdentity:
        DebuggerLocalProcessAttachWriteInterlockIdentity?
    let ownedProcessLauncherRegistryIdentity: ObjectIdentifier?
    let targetlessTransportFactoryRegistryIdentity: ObjectIdentifier?
    let ownedInfrastructureInterlockIdentity:
        DebuggerLocalProcessAttachWriteInterlockIdentity?
    let observationPolicyProviderIsAvailable: Bool
    let observationPolicyRegistryAuthority:
        DebuggerLocalProcessObservationPolicyRegistryAuthority?

    var isObservationPolicyAuthorityReady: Bool {
        guard let sessionLeaseRegistryIdentity,
              let sessionLeaseInterlockIdentity,
              let ownedProcessLauncherRegistryIdentity,
              let targetlessTransportFactoryRegistryIdentity,
              let ownedInfrastructureInterlockIdentity,
              let observationPolicyRegistryAuthority else {
            return false
        }
        return observationPolicyProviderIsAvailable
            && observationPolicyRegistryAuthority.hostIdentity.isCurrentHostProcess
            && ownedProcessLauncherRegistryIdentity
                == targetlessTransportFactoryRegistryIdentity
            && observationPolicyRegistryAuthority.sessionLeaseRegistryID
                == sessionLeaseRegistryIdentity
            && observationPolicyRegistryAuthority.ownedInfrastructureRegistryID
                == ownedProcessLauncherRegistryIdentity
            && observationPolicyRegistryAuthority.attachWriteInterlockIdentity
                == sessionLeaseInterlockIdentity
            && observationPolicyRegistryAuthority.attachWriteInterlockIdentity
                == ownedInfrastructureInterlockIdentity
    }
}

/// One-shot typed command material consumed only after reducer admission. The producer validates
/// every rendered command before installation; the coordinator then binds it to the request ID it
/// minted, so this seam cannot accept an arbitrary console command from a UI snapshot.
actor PersistentLLDBProductionRequestPreparer: PersistentLLDBCLIRequestPreparing {
    struct VariableRefreshExpectation: Sendable {
        let token: Data
        let coordinate: DebuggerInspectionCoordinate
        let processID: Int32
        let observedStopID: UInt32
        let threadID: UInt64
        let frameIndex: UInt32
        let programCounter: UInt64
    }

    enum ResponseProjection: Sendable {
        case none
        case stoppedData
        case stoppedDataWithVariables(VariableRefreshExpectation)
        case variableChildren(VariableRefreshExpectation, DebuggerVariableExpansionRequest)
        case memoryWriteReadback(address: UInt64, bytes: [UInt8])
        case breakpoints([DebuggerTransportBreakpoint], requireCreationProof: Bool)
        case expression
        case watchpoints
    }

    private struct Template: Sendable {
        let commands: [String]
        let observedPIDRequirement: LLDBCLIObservedPIDRequirement
        let timeout: Duration
        let responseProjection: ResponseProjection
    }

    private var templates: [DebuggerOperation: Template] = [:]
    private var responseProjections: [DebuggerRequestID: ResponseProjection] = [:]
    private var failedSemanticCommandIndexes: [DebuggerRequestID: Int] = [:]

    func install(
        operation: DebuggerOperation,
        commands: [String],
        observedPIDRequirement: LLDBCLIObservedPIDRequirement = .required,
        timeout: Duration,
        responseProjection: ResponseProjection = .none
    ) throws {
        for command in commands {
            try LLDBCLITranscriptDecoder.validateRenderedCommand(command)
        }
        templates[operation] = Template(
            commands: commands,
            observedPIDRequirement: observedPIDRequirement,
            timeout: timeout,
            responseProjection: responseProjection
        )
    }

    func discard(operation: DebuggerOperation) {
        templates[operation] = nil
    }

    func discardOutstandingResponses() {
        responseProjections.removeAll(keepingCapacity: false)
        failedSemanticCommandIndexes.removeAll(keepingCapacity: false)
    }

    func prepareRequest(
        for context: DebuggerRequestContext
    ) async throws -> PersistentLLDBCLIRequest {
        guard let template = templates.removeValue(forKey: context.operation) else {
            throw PersistentLLDBProductionControllerError.missingPreparedOperation
        }
        responseProjections[context.id] = template.responseProjection
        return try PersistentLLDBCLIRequest(
            context: context,
            semanticCommands: template.commands,
            observedPIDRequirement: template.observedPIDRequirement,
            timeout: template.timeout
        )
    }

    func reducerPayloads(
        for context: DebuggerRequestContext,
        transcript: LLDBCLITranscriptResult
    ) async throws -> [DebuggerEventPayload] {
        let projection = responseProjections.removeValue(forKey: context.id) ?? .none
        let trustedTranscript = transcript.trustedSemanticTranscript
        switch projection {
        case .none:
            return []
        case .stoppedData:
            guard let data = Self.makeStoppedData(from: trustedTranscript) else {
                throw PersistentLLDBProductionControllerError.unusableStoppedData
            }
            return [.stoppedDataRefreshed(data)]
        case .stoppedDataWithVariables(let expectation):
            guard let base = Self.makeStoppedData(from: trustedTranscript),
                  let variables = try Self.makeVariableSnapshots(
                    from: trustedTranscript,
                    expectation: expectation
                  ) else {
                throw PersistentLLDBProductionControllerError.unusableStoppedData
            }
            return [.stoppedDataRefreshed(DebuggerStoppedData(
                threads: base.threads,
                threadIdentityDiagnostic: base.threadIdentityDiagnostic,
                frames: base.frames,
                registers: base.registers,
                memoryPreviews: base.memoryPreviews,
                variables: .available(variables),
                selectedThreadID: base.selectedThreadID,
                selectedFrameID: Int(expectation.frameIndex),
                currentProgramCounter: expectation.programCounter
            ))]
        case .variableChildren(let expectation, let request):
            guard let snapshot = try Self.makeVariableChildSnapshot(
                from: trustedTranscript,
                expectation: expectation,
                request: request
            ) else {
                throw PersistentLLDBProductionControllerError.unusableStoppedData
            }
            return [.variableChildrenRefreshed(request: request, snapshot: snapshot)]
        case .memoryWriteReadback(let address, let bytes):
            guard let data = Self.makeStoppedData(from: trustedTranscript),
                  case .available(let previews) = data.memoryPreviews,
                  previews.contains(where: { preview in
                      preview.address == address
                          && preview.bytes.count >= bytes.count
                          && Array(preview.bytes.prefix(bytes.count)) == bytes
                  }) else {
                throw PersistentLLDBProductionControllerError.unusableStoppedData
            }
            return [.stoppedDataRefreshed(data)]
        case .breakpoints(let breakpoints, let requireCreationProof):
            if requireCreationProof {
                for breakpoint in breakpoints where breakpoint.isEnabled {
                    let renderedAddress = String(
                        format: "0x%016llx",
                        breakpoint.address
                    )
                    guard trustedTranscript.localizedCaseInsensitiveContains(
                        renderedAddress
                    ) else {
                        throw PersistentLLDBProductionControllerError.unusableStoppedData
                    }
                }
            }
            return [.breakpointsReplaced(breakpoints)]
        case .watchpoints:
            guard let response = transcript.semanticCommandTranscripts.last else {
                throw DebuggerWatchpointError.invalidResponse
            }
            return [.watchpointsUpdated(try LLDBWatchpointProgram.decode(transcript: response))]
        case .expression:
            guard let parsed = XcodeLLDBCommandLineAdapter.parseExpressionResult(
                from: trustedTranscript
            ), !parsed.value.lowercased().hasPrefix("error:") else {
                throw PersistentLLDBProductionControllerError.unusableExpressionResult
            }
            return [
                .expressionEvaluated(
                    DebuggerExpressionEvaluation(
                        displayValue: parsed.value,
                        typeName: parsed.type
                    )
                )
            ]
        }
    }

    func validateResponse(
        for context: DebuggerRequestContext,
        transcript: LLDBCLITranscriptResult
    ) async throws {
        guard transcript.semanticCommandsSucceeded else {
            if let index = transcript.firstFailedSemanticCommandIndex {
                failedSemanticCommandIndexes[context.id] = index
            }
            throw PersistentLLDBProductionControllerError.unusableStoppedData
        }
    }

    func takeFailedSemanticCommandIndex(for requestID: DebuggerRequestID) -> Int? {
        failedSemanticCommandIndexes.removeValue(forKey: requestID)
    }

    /// Internal (not private) so CoreTests can project a captured `thread list` transcript.
    static func makeStoppedData(from transcript: String) -> DebuggerStoppedData? {
        let threadSummaries = XcodeLLDBCommandLineAdapter.parseThreadSummaries(from: transcript)
        let threadIdentityDiagnostic = XcodeLLDBCommandLineAdapter.parseThreadIdentityDiagnostic(from: transcript)
        let frameSummaries = XcodeLLDBCommandLineAdapter.parseFrameSummaries(from: transcript)
        let registerSummaries = XcodeLLDBCommandLineAdapter.parseRegisterSummaries(from: transcript)
        let memorySummaries = XcodeLLDBCommandLineAdapter.parseMemorySummaries(from: transcript)
        guard threadIdentityDiagnostic != nil || !threadSummaries.isEmpty || !frameSummaries.isEmpty
                || !registerSummaries.isEmpty || !memorySummaries.isEmpty else {
            return nil
        }

        let threads = threadSummaries.map { summary in
            DebuggerStoppedThread(
                identifier: summary.index,
                threadID: summary.tid,
                queueName: summary.queueName,
                stopReason: summary.stopReason.map(transportStopReason),
                isSelected: summary.isSelected,
                topFrameAddress: summary.topFrameAddress,
                topFrameFunctionName: summary.topFrameFunctionName,
                name: summary.name
            )
        }
        let frames = frameSummaries.map {
            DebuggerStoppedFrame(
                identifier: $0.index,
                address: $0.address,
                functionName: $0.functionName,
                moduleName: $0.moduleName,
                sourceLocation: $0.sourceLocation
            )
        }
        let registers = registerSummaries.map {
            DebuggerStoppedRegister(
                name: $0.name,
                value: $0.value,
                role: $0.role,
                group: transportRegisterGroup($0.group)
            )
        }
        let memory = memorySummaries.map {
            DebuggerStoppedMemoryPreview(
                address: $0.address,
                bytes: $0.previewBytes,
                label: $0.label
            )
        }
        return DebuggerStoppedData(
            threads: threadIdentityDiagnostic == nil ? .available(threads) : .unavailable,
            threadIdentityDiagnostic: threadIdentityDiagnostic,
            frames: .available(frames),
            registers: .available(registers),
            memoryPreviews: .available(memory),
            variables: .unavailable,
            selectedThreadID: threadIdentityDiagnostic == nil
                ? threads.first(where: { $0.isSelected })?.identifier : nil,
            selectedFrameID: frames.first?.identifier,
            currentProgramCounter: frames.first(where: { $0.identifier == 0 })?.address
                ?? frames.first?.address
        )
    }

    private static func makeVariableSnapshots(
        from transcript: String,
        expectation: VariableRefreshExpectation
    ) throws -> [DebuggerVariableSnapshot]? {
        let prefix = "MACSCOPE_LLDB_VARIABLE_SNAPSHOT_V1 "
        let framed = transcript.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix(prefix) }
        guard framed.count == 1 else { return nil }
        let decoded = try LLDBVariableSnapshotDecoder().decodeSemanticTranscript(
            String(framed[0]) + "\n"
        )
        guard decoded.token == expectation.token,
              decoded.observedProcessID == expectation.processID,
              decoded.observedStopID == expectation.observedStopID,
              decoded.threadID == expectation.threadID,
              decoded.frameIndex == expectation.frameIndex,
              decoded.programCounter == expectation.programCounter else { return nil }

        let mappings: [(LLDBVariableScope, DebuggerVariableScopeKind)] = [
            (.argument, .arguments), (.local, .locals), (.staticVariable, .statics),
        ]
        return try mappings.map { source, destination in
            let values = decoded.variables.filter { $0.scope == source }
            let nodes = try values.map { value -> DebuggerVariableNode in
                let pathComponents = [destination.rawValue, String(value.ordinal), value.name]
                guard let token = DebuggerVariablePathToken(
                    coordinate: expectation.coordinate,
                    components: pathComponents
                ) else { throw PersistentLLDBProductionControllerError.unusableStoppedData }
                let state: DebuggerVariableValueState
                switch value.valueState {
                case .available(let rendered, let summary):
                    guard let display = summary ?? rendered, !display.isEmpty else {
                        throw PersistentLLDBProductionControllerError.unusableStoppedData
                    }
                    state = .value(display)
                case .optimizedOut:
                    state = .optimizedOut
                case .unavailable:
                    state = .unavailable(reason: "LLDB reported this value unavailable.")
                case .failed(let diagnostic):
                    state = .failed(reason: diagnostic)
                }
                guard let node = DebuggerVariableNode(
                    id: token,
                    name: value.name,
                    typeName: value.typeName,
                    value: state,
                    childCount: Int(value.childCount),
                    pathComponents: pathComponents
                ) else { throw PersistentLLDBProductionControllerError.unusableStoppedData }
                return node
            }
            guard let snapshot = DebuggerVariableSnapshot(
                coordinate: expectation.coordinate,
                scope: destination,
                nodes: nodes,
                depth: 0,
                wasTruncated: {
                    switch source {
                    case .argument: decoded.argumentWasTruncated
                    case .local: decoded.localWasTruncated
                    case .staticVariable: decoded.staticWasTruncated
                    }
                }()
            ) else { throw PersistentLLDBProductionControllerError.unusableStoppedData }
            return snapshot
        }
    }

    private static func makeVariableChildSnapshot(
        from transcript: String,
        expectation: VariableRefreshExpectation,
        request: DebuggerVariableExpansionRequest
    ) throws -> DebuggerVariableSnapshot? {
        guard isValidVariableChildRequestShape(request),
              expectation.coordinate == request.coordinate else { return nil }
        let prefix = "MACSCOPE_LLDB_VARIABLE_SNAPSHOT_V1 "
        let framed = transcript.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix(prefix) }
        guard framed.count == 1 else { return nil }
        let decoded = try LLDBVariableSnapshotDecoder().decodeSemanticTranscript(
            String(framed[0]) + "\n"
        )
        guard decoded.token == expectation.token,
              decoded.observedProcessID == expectation.processID,
              decoded.observedStopID == expectation.observedStopID,
              decoded.threadID == expectation.threadID,
              decoded.frameIndex == expectation.frameIndex,
              decoded.programCounter == expectation.programCounter else { return nil }

        let scope: DebuggerVariableScopeKind
        let expectedSource: LLDBVariableScope
        let wasTruncated: Bool
        switch request.pathComponents[0] {
        case DebuggerVariableScopeKind.arguments.rawValue:
            scope = .arguments
            expectedSource = .argument
            wasTruncated = decoded.argumentWasTruncated
            guard decoded.localOmittedCount == 0,
                  !decoded.localWasTruncated,
                  decoded.staticOmittedCount == 0,
                  !decoded.staticWasTruncated else { return nil }
        case DebuggerVariableScopeKind.locals.rawValue:
            scope = .locals
            expectedSource = .local
            wasTruncated = decoded.localWasTruncated
            guard decoded.argumentOmittedCount == 0,
                  !decoded.argumentWasTruncated,
                  decoded.staticOmittedCount == 0,
                  !decoded.staticWasTruncated else { return nil }
        case DebuggerVariableScopeKind.statics.rawValue:
            scope = .statics
            expectedSource = .staticVariable
            wasTruncated = decoded.staticWasTruncated
            guard decoded.argumentOmittedCount == 0,
                  !decoded.argumentWasTruncated,
                  decoded.localOmittedCount == 0,
                  !decoded.localWasTruncated else { return nil }
        default:
            return nil
        }
        guard decoded.variables.count <= DebuggerVariableNode.maximumChildCount,
              decoded.variables.allSatisfy({ $0.scope == expectedSource }) else { return nil }

        let nodes = try decoded.variables.map { value -> DebuggerVariableNode in
            let childPathComponents = request.pathComponents + [
                String(value.ordinal), value.name,
            ]
            guard let token = DebuggerVariablePathToken(
                coordinate: expectation.coordinate,
                components: childPathComponents
            ) else { throw PersistentLLDBProductionControllerError.unusableStoppedData }
            let state: DebuggerVariableValueState
            switch value.valueState {
            case .available(let rendered, let summary):
                guard let display = summary ?? rendered, !display.isEmpty else {
                    throw PersistentLLDBProductionControllerError.unusableStoppedData
                }
                state = .value(display)
            case .optimizedOut:
                state = .optimizedOut
            case .unavailable:
                state = .unavailable(reason: "LLDB reported this value unavailable.")
            case .failed:
                state = .failed(reason: "LLDB could not read this child value.")
            }
            guard let node = DebuggerVariableNode(
                id: token,
                name: value.name,
                typeName: value.typeName,
                value: state,
                childCount: Int(value.childCount),
                pathComponents: childPathComponents
            ) else { throw PersistentLLDBProductionControllerError.unusableStoppedData }
            return node
        }
        return DebuggerVariableSnapshot(
            coordinate: expectation.coordinate,
            scope: scope,
            nodes: nodes,
            depth: request.depth,
            wasTruncated: wasTruncated
        )
    }

    fileprivate nonisolated static func isValidVariableChildRequestShape(
        _ request: DebuggerVariableExpansionRequest
    ) -> Bool {
        let components = request.pathComponents
        guard components.count >= 3,
              !components.count.isMultiple(of: 2),
              components.count + 2 <= DebuggerVariablePathToken.maximumComponentCount,
              request.depth == (components.count - 1) / 2 else {
            return false
        }
        return [
            DebuggerVariableScopeKind.arguments.rawValue,
            DebuggerVariableScopeKind.locals.rawValue,
            DebuggerVariableScopeKind.statics.rawValue,
        ].contains(components[0])
    }

    private static func transportStopReason(
        _ reason: DebuggerPauseReason
    ) -> DebuggerTransportStopReason {
        switch reason {
        case .breakpoint(let address): .breakpoint(address: address)
        case .step: .step
        case .signal(let signal): .signal(signal)
        case .userRequested: .userRequested
        case .unknown(let detail): .unknown(detail)
        }
    }

    private static func transportRegisterGroup(
        _ group: DebuggerRegisterGroup
    ) -> DebuggerStoppedRegisterGroup {
        switch group {
        case .generalPurpose: .generalPurpose
        case .floatingPoint: .floatingPoint
        case .system: .system
        case .other: .other
        }
    }
}

/// Production owner of one persistent, correlated Xcode-LLDB interpreter.
///
/// Presentation snapshots are output-only compatibility projections. Every operation is admitted
/// against reducer-owned coordinates; caller snapshots are retained only to preserve the existing
/// facade signature and never supply a PID, lifecycle revision, or stop revision.
@MainActor
final class PersistentLLDBProductionController {
    static let missingOwnedInfrastructureAuthorityReason =
        "Persistent Xcode LLDB launch requires the app-global owned-process authority."
    static let retiredControllerReason =
        "This workspace debugger authority has been retired."

    typealias ProcessChannelLauncher = @MainActor @Sendable (
        PersistentLLDBCLIProcessLaunchPlan
    ) async -> PersistentLLDBProductionProcessChannelLaunchOutcome

    private enum SessionLeaseAuthority {
        case unavailable(ownerID: DebuggerSessionLeaseOwnerID)
        case shared(
            registry: DebuggerSessionLeaseRegistry,
            ownerID: DebuggerSessionLeaseOwnerID
        )

        var projection: PersistentLLDBSessionLeaseAuthorityProjection {
            switch self {
            case .unavailable(let ownerID):
                PersistentLLDBSessionLeaseAuthorityProjection(
                    registryIdentity: nil,
                    ownerID: ownerID
                )
            case .shared(let registry, let ownerID):
                PersistentLLDBSessionLeaseAuthorityProjection(
                    registryIdentity: ObjectIdentifier(registry),
                    ownerID: ownerID
                )
            }
        }

        var registry: DebuggerSessionLeaseRegistry? {
            switch self {
            case .unavailable:
                nil
            case .shared(let registry, _):
                registry
            }
        }
    }

    private enum ControllerLifecycle: Equatable {
        case active
        case retiring
        case retired
    }

    private struct Session {
        let adapter: PersistentLLDBCLIAdapter
        let coordinator: PersistentLLDBSessionCoordinator
        let preparer: PersistentLLDBProductionRequestPreparer
        let runtimeModuleCollector: DebuggerRuntimeModuleInventoryCollector
        let runtimeModuleToken: Data
        let adapterGeneration: UInt64
        let logicalBreakpointOwnershipTagDigest: DebuggerBreakpointDigest
        let executableName: String
        let exactAttachedSessionEvidence: PersistentLLDBExactAttachedSessionEvidence?
    }

    private struct UnresolvedRecoveryBlocker: Sendable {
        let reason: DebuggerRecoveryReason
        let authority: DebuggerSessionTargetAuthority?
        let reobservation: DebuggerLocalProcessResolution<DebuggerLocalProcessIdentity>?
    }

    private struct RecoveryOutcome {
        let snapshot: DebuggerSessionSnapshot
        let isResolved: Bool
    }

    private struct UnresolvedPreDispatchAdapterBlocker {
        let adapter: PersistentLLDBCLIAdapter
    }

    private struct ExactAttachRuntimeAuthority {
        let registry: DebuggerSessionLeaseRegistry
        let ownerID: DebuggerSessionLeaseOwnerID
        let factory: PersistentLLDBTargetlessTransportFactory
        let policyProvider: DebuggerLocalProcessObservationPolicyProvider
        let interlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity
    }

    private struct ExactAttachPrePermitCleanupOutcome {
        let leaseWasRemoved: Bool
        let adapterWasProvenRetired: Bool
    }

    private struct PendingRunToCursorBreakpoint {
        let epoch: DebuggerSessionEpoch
        let receipt: LLDBRunToCursorPrivateReceipt
        let ownerDigest: DebuggerBreakpointDigest
        let token: Data
    }

    private let toolchain: DebuggerLLDBToolchain
    private let environment: [String: String]
    private let fallbackWorkingDirectory: String
    private let commandTimeout: Duration
    private let pollTimeout: Duration
    private let inboundNeedleProbe: PersistentLLDBCLIInboundNeedleProbe?
    private let launchedProcessEvidenceProvider: any DebuggerLocalProcessEvidenceProviding
    private let processIdentityReobserver: any DebuggerLocalProcessIdentityReobserving
    private let launchedDebuggeeKiller: LaunchedDebuggeeKiller
    /// Retained only as future exact-attach authorization input. Its absence is fail-closed for
    /// attach readiness but independent of the already-authorized exact launch path.
    private let observationPolicyProvider: DebuggerLocalProcessObservationPolicyProvider?
    private let ownedInfrastructureInterlockIdentity:
        DebuggerLocalProcessAttachWriteInterlockIdentity?
    private let launchGateProbe: @Sendable () async -> Void
    private let processChannelLauncher: ProcessChannelLauncher?
    /// Production interpreters and the dormant targetless attach factory must share the exact
    /// app-global owned-process authority. Test-injected launchers remain an explicit override.
    private let ownedProcessChannelLauncher: PersistentLLDBOwnedProcessChannelLauncher?
    private let targetlessTransportFactory: PersistentLLDBTargetlessTransportFactory?
    /// Exact-attach ownership is optional until the app composition root injects the one
    /// process-global actor. An absent actor is an explicit unavailable state; it never causes
    /// this controller to synthesize an authority. The owner ID is minted once per controller
    /// lifetime and remains stable across every interpreter/session generation it creates.
    private let sessionLeaseAuthority: SessionLeaseAuthority

    /// A status poll's exchange deadline. A poll carries no command, so a healthy LLDB answers
    /// at once; the deadline only bounds how long a stalled LLDB is tolerated before the whole
    /// adapter generation is invalidated and the session retired. It used to be 1 s (2 s with
    /// logical-callback authority). §4.88: a poll written while LLDB is still handling an
    /// asynchronous stop (it prints `Process N stopped` … the source listing … `Target 0:
    /// stopped.` first) gets no command or status output until that handling finishes, and under
    /// load that took longer than 2 s. The async block itself is harmless (the decoder keeps it as
    /// console text; observation reads only the status segment and payloads only the per-command
    /// results), but the late sentinel tripped the short deadline and killed a healthy session.
    /// Polls now share the ordinary exchange ceiling: bounded by the controller's command timeout
    /// (default 10 s) and never above 10 s.
    nonisolated static let maximumPollTimeout: Duration = .seconds(10)
    nonisolated static let maximumLogicalCallbackPollTimeout: Duration = .seconds(10)

    nonisolated static func resolvedPollTimeout(for commandTimeout: Duration) -> Duration {
        min(commandTimeout, maximumPollTimeout)
    }

    nonisolated static func resolvedPollTimeout(
        for commandTimeout: Duration,
        hasLogicalCallbackAuthority: Bool
    ) -> Duration {
        min(
            commandTimeout,
            hasLogicalCallbackAuthority
                ? maximumLogicalCallbackPollTimeout
                : maximumPollTimeout
        )
    }

    nonisolated static func shouldDiscardPendingRunToCursorBreakpoint(
        pendingEpoch: DebuggerSessionEpoch,
        resultEpoch: DebuggerSessionEpoch,
        resultIsTerminal: Bool
    ) -> Bool {
        resultIsTerminal && pendingRunToCursorAuthorityMatches(
            pendingEpoch: pendingEpoch,
            sessionEpoch: resultEpoch
        )
    }

    nonisolated static func pendingRunToCursorAuthorityMatches(
        pendingEpoch: DebuggerSessionEpoch,
        sessionEpoch: DebuggerSessionEpoch
    ) -> Bool {
        pendingEpoch == sessionEpoch
    }

    nonisolated static func exactLaunchExecutionResult(
        _ result: PersistentLLDBExactLaunchTransactionResult
    ) -> PersistentLLDBSessionExecutionResult {
        precondition(result.requestID.epoch == result.reducerState.epoch)
        precondition(
            result.requestID.sequence == result.reducerState.lastAdmittedRequestSequence
        )
        precondition(result.reducerState.acceptedTargetAuthority == result.authority)
        return PersistentLLDBSessionExecutionResult(
            requestID: result.requestID,
            reducerState: result.reducerState
        )
    }

    nonisolated static func exactLaunchFailureAdapterRetirementPolicy(
        for phase: DebuggerReducerProcessPhase
    ) -> PersistentLLDBExactLaunchAdapterRetirementPolicy {
        _ = phase
        // No controller path writes `quit`: first-shutdown-mode wins inside the adapter, so even a
        // proven idle cleanup must choose command-free retirement before any racing cleanup task.
        return .retainedAdapterOnly
    }

    nonisolated static func isExactLaunchedRecoveryTerminal(
        _ state: DebuggerReducerState,
        authority: DebuggerSessionTargetAuthority
    ) -> Bool {
        guard state.isInvalidated,
              case .launched = authority.origin,
              state.pendingRequest == nil,
              state.acceptedTargetAuthority == authority,
              state.observedProcessID == authority.processID,
              state.stopRevision == nil else { return false }
        switch (state.processPhase, state.targetDisposition) {
        case let (.exited(processID, phaseCode), .exited(dispositionCode)):
            return processID == authority.processID && phaseCode == dispositionCode
        case let (.terminated(processID), .terminated):
            return processID == authority.processID
        default:
            return false
        }
    }

    nonisolated static func isExactAttachedRecoveryTerminal(
        _ state: DebuggerReducerState,
        authority: DebuggerSessionTargetAuthority
    ) -> Bool {
        guard state.isInvalidated,
              case .attached = authority.origin,
              state.pendingRequest == nil,
              state.acceptedTargetAuthority == authority,
              state.observedProcessID == authority.processID,
              state.stopRevision == nil,
              case .detached(let processID) = state.processPhase,
              processID == authority.processID,
              state.targetDisposition == .detached else { return false }
        return true
    }

    nonisolated static func isExactAttachedExternalExitTerminal(
        _ state: DebuggerReducerState,
        authority: DebuggerSessionTargetAuthority
    ) -> Bool {
        guard state.isInvalidated,
              case .attached = authority.origin,
              state.pendingRequest == nil,
              state.acceptedTargetAuthority == authority,
              state.observedProcessID == authority.processID,
              state.stopRevision == nil else { return false }
        guard case .exited(let processID, let phaseCode) = state.processPhase,
              processID == authority.processID,
              state.targetDisposition == .exited(code: phaseCode) else { return false }
        return true
    }

    /// The external-exit cleanup vocabulary deliberately contains no debugger-command closure.
    /// Once exit is observed, every path retires the exact adapter first; only valid evidence plus
    /// a proven retirement may enter the registry's atomic absence-and-release transaction.
    nonisolated static func settleExactAttachedExternalExit<RetirementProof: Sendable>(
        evidenceIsValid: Bool,
        prepareForRetirement: @escaping @Sendable () async -> Void,
        retireExactAdapter: @escaping @Sendable () async -> RetirementProof?,
        completeRelease: @escaping @Sendable (RetirementProof) async throws -> Void,
        pinDisposition: @escaping @Sendable () async -> Void
    ) async -> PersistentLLDBExactAttachedExternalExitSettlementOutcome {
        await prepareForRetirement()
        let retirementProof = await retireExactAdapter()
        guard evidenceIsValid, let retirementProof else {
            await pinDisposition()
            return .unresolved
        }
        do {
            try await completeRelease(retirementProof)
            return .released
        } catch {
            await pinDisposition()
            return .unresolved
        }
    }

    /// Stable only within one retained interpreter generation. The session epoch is random and
    /// the domain separator prevents this tag from being reused as a transport transaction token.
    nonisolated static func logicalBreakpointOwnershipTagDigest(
        epoch: DebuggerSessionEpoch,
        adapterGeneration: UInt64
    ) -> DebuggerBreakpointDigest {
        precondition(adapterGeneration > 0)
        var material = Data("MacScope.WS21.LogicalBreakpointOwnership.v1".utf8)
        material.append(0)
        material.append(contentsOf: epoch.rawValue.uuidString.lowercased().utf8)
        material.append(0)
        material.append(contentsOf: String(adapterGeneration).utf8)
        return DebuggerBreakpointDigest(Data(SHA256.hash(data: material)))!
    }

    /// Correlates one private helper exchange without allowing the token to alter canonical plan
    /// identity. A unique transaction UUID makes this value unique within the retained session.
    nonisolated static func logicalBreakpointTransactionToken(
        transactionID: DebuggerBreakpointBindingTransactionID,
        epoch: DebuggerSessionEpoch,
        adapterGeneration: UInt64
    ) -> Data {
        precondition(adapterGeneration > 0)
        var material = Data("MacScope.WS21.LogicalBreakpointTransaction.v1".utf8)
        material.append(0)
        material.append(contentsOf: epoch.rawValue.uuidString.lowercased().utf8)
        material.append(0)
        material.append(contentsOf: String(adapterGeneration).utf8)
        material.append(0)
        material.append(contentsOf: transactionID.rawValue.uuidString.lowercased().utf8)
        return Data(SHA256.hash(data: material))
    }

    nonisolated static func runToCursorOwnerDigest(
        epoch: DebuggerSessionEpoch,
        adapterGeneration: UInt64
    ) -> DebuggerBreakpointDigest {
        precondition(adapterGeneration > 0)
        var material = Data("MacScope.WS21.RunToCursorOwner.v1".utf8)
        material.append(0)
        material.append(contentsOf: epoch.rawValue.uuidString.lowercased().utf8)
        material.append(0)
        material.append(contentsOf: String(adapterGeneration).utf8)
        return DebuggerBreakpointDigest(Data(SHA256.hash(data: material)))!
    }

    nonisolated static func runToCursorToken(
        runID: LLDBRunToCursorRunID,
        epoch: DebuggerSessionEpoch,
        adapterGeneration: UInt64
    ) -> Data {
        var material = Data("MacScope.WS21.RunToCursorTransaction.v1".utf8)
        material.append(0)
        material.append(contentsOf: epoch.rawValue.uuidString.lowercased().utf8)
        material.append(0)
        material.append(contentsOf: String(adapterGeneration).utf8)
        material.append(0)
        material.append(contentsOf: runID.rawValue.uuidString.lowercased().utf8)
        return Data(SHA256.hash(data: material))
    }

    nonisolated static func requireRunToCursorAuthority(
        _ state: DebuggerReducerState,
        request: DebuggerRunToCursorRequest,
        adapterGeneration: UInt64
    ) throws -> DebuggerRuntimeModuleInventory {
        let resolved = request.resolvedAddress
        let key = resolved.projectionKey
        guard adapterGeneration > 0,
              request.observedStopID > 0,
              !state.isInvalidated,
              state.pendingRequest == nil,
              case .stopped(let processID, _) = state.processPhase,
              processID > 0,
              state.observedProcessID == processID,
              state.stopCoordinate == key.stopCoordinate,
              key.observedPID == processID,
              state.runtimeModuleInventoryState.currentStop == key.stopCoordinate,
              state.runtimeModuleInventoryState.processID == processID,
              state.runtimeModuleInventoryState.authorityRevision == key.authorityRevision,
              case .available(let inventory) = state.runtimeModuleInventoryState.authority,
              inventory.stop == key.stopCoordinate,
              inventory.processID == processID,
              inventory.observedStopID == request.observedStopID,
              inventory.revision == key.inventoryRevision,
              state.runtimeModuleInventoryState.inventoryRevision == inventory.revision,
              resolved.moduleInstanceID.processID == processID,
              resolved.moduleInstanceID.stop == inventory.stop,
              resolved.moduleInstanceID.inventoryRevision == inventory.revision,
              inventory.modules.contains(where: { $0.id == resolved.moduleInstanceID }) else {
            throw PersistentLLDBProductionControllerError.unusableRunToCursorAuthority
        }
        return inventory
    }

    /// Rechecks only reducer-owned stopped authority after the controller operation gate is held.
    /// Presentation snapshots and caller-authored process coordinates never enter this proof.
    nonisolated static func requireLogicalBreakpointReconciliationAuthority(
        _ state: DebuggerReducerState,
        request: DebuggerLogicalBreakpointReconcileRequest,
        adapterGeneration: UInt64
    ) throws -> DebuggerRuntimeModuleInventory {
        guard adapterGeneration > 0,
              !state.isInvalidated,
              state.pendingRequest == nil,
              case .stopped(let processID, _) = state.processPhase,
              processID > 0,
              state.observedProcessID == processID,
              let stop = state.stopCoordinate,
              stop == request.observation.mappingKey.stopCoordinate,
              request.observation.mappingKey.observedPID == processID,
              state.runtimeModuleInventoryState.currentStop == stop,
              state.runtimeModuleInventoryState.processID == processID,
              state.runtimeModuleInventoryState.authorityRevision
                == request.observation.mappingKey.authorityRevision,
              case .available(let inventory) = state.runtimeModuleInventoryState.authority,
              inventory.stop == stop,
              inventory.processID == processID,
              inventory.observedStopID > 0,
              inventory.revision == request.observation.mappingKey.inventoryRevision,
              state.runtimeModuleInventoryState.inventoryRevision == inventory.revision,
              !state.breakpointBindingState.isTerminal,
              !state.breakpointBindingState.isInvalidated,
              state.breakpointBindingState.pendingPlan == nil,
              state.breakpointBindingState.currentStop == stop,
              state.breakpointBindingState.adapterGeneration == adapterGeneration,
              state.breakpointBindingState.observedPID == processID,
              state.breakpointBindingState.observedStopID == inventory.observedStopID else {
            throw PersistentLLDBProductionControllerError
                .unusableLogicalBreakpointAuthority
        }
        return inventory
    }

    nonisolated static func logicalBreakpointFailureRecovery(
        classification: LLDBLogicalBreakpointTransactionFailureClassification,
        sessionAuthorityLost: Bool
    ) -> PersistentLLDBLogicalBreakpointControllerRecovery {
        switch classification {
        case .cancelBeforeWrite:
            return sessionAuthorityLost ? .invalidateSessionAndShutdownAdapter : .none
        case .rejectMalformedAfterPossibleWrite(
            cleanup: _,
            retainValidatedCompleteReceipt: _,
            targetRecoveryRequired: let required
        ):
            if required { return .boundedTargetRecovery }
            return sessionAuthorityLost ? .invalidateSessionAndShutdownAdapter : .none
        }
    }

    nonisolated static func authoritativeStateAfterAutomaticStoppedRefreshFailure(
        _ state: DebuggerReducerState
    ) throws -> DebuggerReducerState {
        guard !state.isInvalidated else {
            throw DebuggerClientError.backendFailure(
                "Snapshot Refresh invalidated the correlated LLDB session."
            )
        }
        return state
    }

    /// Preserve a successful expression value only when the failed automatic collection left an
    /// exact stopped-process authority and published its bounded compatibility tombstone. A nil
    /// result means the caller must propagate the refresh failure; invalidated sessions additionally
    /// require controller-owned transport cleanup before that propagation.
    nonisolated static func expressionResultAfterRuntimeModuleRefreshFailure(
        value: String,
        type: String?,
        authoritativeState: DebuggerReducerState,
        executableName: String
    ) -> DebuggerExpressionResult? {
        guard !authoritativeState.isInvalidated,
              case .stopped = authoritativeState.processPhase,
              case .unavailable(.refreshFailed) =
                authoritativeState.runtimeModuleInventoryState.authority else {
            return nil
        }
        return DebuggerExpressionResult(
            value: value,
            type: type,
            refreshedSnapshot: DebuggerTransportSnapshotProjector.project(
                authoritativeState,
                executableName: executableName
            )
        )
    }

    nonisolated static func requireObservedExitAfterRunToCursorFailureRecovery(
        _ state: DebuggerReducerState
    ) throws {
        guard case .exited(let processID, _) = state.processPhase,
              state.observedProcessID == processID,
              case .exited = state.targetDisposition else {
            throw DebuggerClientError.backendFailure(
                "Run to Cursor recovery could not prove target exit."
            )
        }
    }

    private var session: Session?
    /// A sealed attach result must remain strongly retained while the registry performs its
    /// cancellation-shielded confirmation, but it is not a usable controller session until that
    /// confirmation returns exact evidence for the same transaction.
    private var provisionalExactAttachSession: Session?
    private var lastExactAttachReservationForTesting: DebuggerSessionLeaseReservation?
    private var pendingRunToCursorBreakpoint: PendingRunToCursorBreakpoint?
    /// Once target disposition is unresolved, removing the dead transport must not silently make a
    /// new launch admissible. This blocker is deliberately write-once for the controller lifetime.
    private var unresolvedRecoveryBlocker: UnresolvedRecoveryBlocker?
    /// A spawned LLDB child whose command-free retirement did not prove both exit and reap stays
    /// retained for the controller lifetime. No later launch may create another child while this
    /// exact process authority is unresolved.
    private var unresolvedPreDispatchAdapterBlocker: UnresolvedPreDispatchAdapterBlocker?
    /// Polls coalesce onto this one task. Pause awaits it before issuing `process interrupt`, so a
    /// pause can sit behind at most one status request and never signals LLDB or the target.
    private var activePoll: Task<PersistentLLDBSessionExecutionResult, Error>?
    private var operationGateIsLocked = false
    private var operationGateWaiters: [CheckedContinuation<Void, Never>] = []
    private var lifecycle = ControllerLifecycle.active
    private var shutdownTask: Task<Void, Never>?
    private var shutdownDrainOwnsOperationGate = false
    private var retirementDrainCount = 0

    private static let stoppedRefreshCommands = [
        XcodeLLDBCommandLineAdapter.liveThreadListCommand,
        XcodeLLDBCommandLineAdapter.liveBacktraceCommand,
        XcodeLLDBCommandLineAdapter.liveRegisterReadCommand,
        XcodeLLDBCommandLineAdapter.liveStackMemoryReadCommand,
    ]

    init(
        toolchain: DebuggerLLDBToolchain,
        environment: [String: String],
        fallbackWorkingDirectory: String,
        commandTimeoutSeconds: TimeInterval,
        inboundNeedleProbe: PersistentLLDBCLIInboundNeedleProbe? = nil,
        launchedProcessEvidenceProvider: any DebuggerLocalProcessEvidenceProviding =
            DarwinDebuggerLocalProcessEvidenceProvider(),
        launchGateProbe: @escaping @Sendable () async -> Void = {},
        processChannelLauncher: ProcessChannelLauncher? = nil,
        targetlessProcessPreparerForTesting:
            PersistentLLDBOwnedProcessChannelLauncher.ProcessPreparer? = nil,
        debuggerSessionLeaseRegistry: DebuggerSessionLeaseRegistry? = nil,
        ownedInfrastructureRegistry: DebuggerOwnedInfrastructureRegistry? = nil,
        observationPolicyProvider: DebuggerLocalProcessObservationPolicyProvider? = nil,
        launchedDebuggeeKiller: @escaping LaunchedDebuggeeKiller =
            PersistentLLDBProductionController.killLaunchedDebuggee
    ) {
        self.launchedDebuggeeKiller = launchedDebuggeeKiller
        self.toolchain = toolchain
        self.environment = environment
        self.fallbackWorkingDirectory = fallbackWorkingDirectory
        let boundedSeconds = commandTimeoutSeconds.isFinite && commandTimeoutSeconds > 0
            ? min(commandTimeoutSeconds, 3_600)
            : 10
        let milliseconds = max(1, Int64((boundedSeconds * 1_000).rounded(.up)))
        let commandTimeout = Duration.milliseconds(milliseconds)
        self.commandTimeout = commandTimeout
        self.pollTimeout = Self.resolvedPollTimeout(for: commandTimeout)
        self.inboundNeedleProbe = inboundNeedleProbe
        self.launchedProcessEvidenceProvider = launchedProcessEvidenceProvider
        let processIdentityObserver = DebuggerLocalProcessIdentityObserver(
            provider: launchedProcessEvidenceProvider
        )
        self.processIdentityReobserver = processIdentityObserver
        self.observationPolicyProvider = observationPolicyProvider
        self.ownedInfrastructureInterlockIdentity =
            ownedInfrastructureRegistry?.attachWriteInterlock.identity
        self.launchGateProbe = launchGateProbe
        self.processChannelLauncher = processChannelLauncher
        if let ownedInfrastructureRegistry {
            self.ownedProcessChannelLauncher = PersistentLLDBOwnedProcessChannelLauncher(
                registry: ownedInfrastructureRegistry
            )
            if let targetlessProcessPreparerForTesting {
                self.targetlessTransportFactory = PersistentLLDBTargetlessTransportFactory(
                    ownedInfrastructureRegistry: ownedInfrastructureRegistry,
                    localProcessEvidenceProvider: launchedProcessEvidenceProvider,
                    processPreparer: targetlessProcessPreparerForTesting
                )
            } else {
                self.targetlessTransportFactory = PersistentLLDBTargetlessTransportFactory(
                    ownedInfrastructureRegistry: ownedInfrastructureRegistry,
                    localProcessEvidenceProvider: launchedProcessEvidenceProvider
                )
            }
        } else {
            self.ownedProcessChannelLauncher = nil
            self.targetlessTransportFactory = nil
        }
        let ownerID = DebuggerSessionLeaseOwnerID(rawValue: UUID())
        if let debuggerSessionLeaseRegistry {
            self.sessionLeaseAuthority = .shared(
                registry: debuggerSessionLeaseRegistry,
                ownerID: ownerID
            )
        } else {
            self.sessionLeaseAuthority = .unavailable(ownerID: ownerID)
        }
    }

    var runtimeAuthorityProjectionForTesting: PersistentLLDBRuntimeAuthorityProjection {
        PersistentLLDBRuntimeAuthorityProjection(
            sessionLeaseRegistryIdentity: sessionLeaseAuthority.projection.registryIdentity,
            sessionLeaseInterlockIdentity:
                sessionLeaseAuthority.registry?.attachWriteInterlock.identity,
            ownedProcessLauncherRegistryIdentity:
                ownedProcessChannelLauncher?.ownedInfrastructureRegistryIdentityForTesting,
            targetlessTransportFactoryRegistryIdentity:
                targetlessTransportFactory?.ownedInfrastructureRegistryIdentityForTesting,
            ownedInfrastructureInterlockIdentity:
                ownedInfrastructureInterlockIdentity,
            observationPolicyProviderIsAvailable: observationPolicyProvider != nil,
            observationPolicyRegistryAuthority:
                observationPolicyProvider?.registryAuthority
        )
    }

    func observationPolicySnapshotForTesting() async
        -> DebuggerLocalProcessResolution<DebuggerLocalProcessObservationPolicySnapshot>?
    {
        guard let observationPolicyProvider else { return nil }
        return await observationPolicyProvider.snapshot()
    }

    var sessionLeaseAuthorityForTesting: PersistentLLDBSessionLeaseAuthorityProjection {
        sessionLeaseAuthority.projection
    }

    var exactAttachedSessionEvidenceForTesting:
        PersistentLLDBExactAttachedSessionEvidence? {
        session?.exactAttachedSessionEvidence
    }

    var lastExactAttachReservationProjectionForTesting:
        DebuggerSessionLeaseReservation? {
        lastExactAttachReservationForTesting
    }

    var hasUnresolvedExactAttachBlockerForTesting: Bool {
        unresolvedRecoveryBlocker != nil
            || unresolvedPreDispatchAdapterBlocker != nil
    }

    var currentSessionCoordinatorIdentityForTesting: ObjectIdentifier? {
        session.map { ObjectIdentifier($0.coordinator) }
    }

    var isRetirementRequestedForTesting: Bool {
        switch lifecycle {
        case .active: false
        case .retiring, .retired: true
        }
    }

    var retirementDrainCountForTesting: Int {
        retirementDrainCount
    }

    deinit {
        let ownerID = sessionLeaseAuthority.projection.ownerID
        if let registry = sessionLeaseAuthority.registry {
            Task { await registry.retireOwner(ownerID) }
        }
        if let adapter = session?.adapter {
            Task { _ = await adapter.retireRetainedAdapterWithoutDebuggerCommand() }
        }
        if let adapter = provisionalExactAttachSession?.adapter {
            Task { _ = await adapter.retireRetainedAdapterWithoutDebuggerCommand() }
        }
        if let adapter = unresolvedPreDispatchAdapterBlocker?.adapter {
            Task { _ = await adapter.retireRetainedAdapterWithoutDebuggerCommand() }
        }
    }

    /// Permanently closes this workspace/controller authority, coalesces duplicate callers onto
    /// one drain, and waits until the operation gate proves every admitted command has settled.
    /// Target cleanup remains origin-aware through the existing recovery boundary; any uncertain
    /// disposition stays pinned and can never reopen admission.
    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        guard lifecycle == .active else { return }

        lifecycle = .retiring
        activePoll?.cancel()
        let task = Task { @MainActor [self] in
            await performShutdownDrain()
        }
        shutdownTask = task
        await task.value
    }

    private func performShutdownDrain() async {
        retirementDrainCount += 1
        let ownerID = sessionLeaseAuthority.projection.ownerID
        if let registry = sessionLeaseAuthority.registry {
            await registry.retireOwner(ownerID)
        }

        await acquireOperationGate()
        shutdownDrainOwnsOperationGate = true
        activePoll?.cancel()
        activePoll = nil

        if let current = session {
            _ = await recoverSessionAssumingOperationGateHeld(
                for: .adapterInterruption,
                in: current
            )
        }
        if let provisional = provisionalExactAttachSession {
            await provisional.preparer.discardOutstandingResponses()
            _ = await provisional.adapter.retireRetainedAdapterWithoutDebuggerCommand()
            provisionalExactAttachSession = nil
        }
        if let blocker = unresolvedPreDispatchAdapterBlocker {
            _ = await blocker.adapter.retireRetainedAdapterWithoutDebuggerCommand()
        }

        pendingRunToCursorBreakpoint = nil
        session = nil
        shutdownDrainOwnsOperationGate = false
        lifecycle = .retired
        releaseOperationGate()
    }

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot {
        try requireActiveController()
        try Task.checkCancellation()
        try await awaitActivePoll()
        try requireActiveController()
        try Task.checkCancellation()
        await acquireOperationGate()
        defer { releaseOperationGate() }
        try requireActiveController()
        try Task.checkCancellation()
        await launchGateProbe()
        try requireActiveController()
        try Task.checkCancellation()
        try await requireNoLiveOrUnknownTargetBeforeLaunch()
        try Task.checkCancellation()

        // Freeze and validate the complete request before stopping an idle prior interpreter or
        // spawning a replacement. The process plan's startup-only async assertion exits the LLDB
        // child before stdin is consumed if async mode cannot be established.
        let plan: DebuggerLLDBSealedLaunchPlan
        do {
            let canonicalExecutablePath = try DebuggerLLDBSealedLaunchPlan
                .prepareCanonicalExecutablePath(configuration: configuration)
            let executableSealingGrant = try await DebuggerExecutableSealer.seal(
                canonicalExecutablePath: canonicalExecutablePath,
                timeout: commandTimeout
            )
            try requireActiveController()
            try Task.checkCancellation()
            plan = try DebuggerLLDBSealedLaunchPlan.make(
                configuration: configuration,
                executableSealingGrant: executableSealingGrant,
                toolchain: toolchain,
                environment: environment,
                fallbackWorkingDirectory: fallbackWorkingDirectory,
                timeout: commandTimeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DebuggerClientError {
            throw error
        } catch {
            throw DebuggerClientError.invalidConfiguration(error.localizedDescription)
        }
        try requireActiveController()
        try Task.checkCancellation()

        try await shutdownIdleSessionAssumingOperationGateHeld()
        try requireActiveController()
        try Task.checkCancellation()

        let epoch = DebuggerSessionEpoch()
        let launchOutcome: PersistentLLDBProductionProcessChannelLaunchOutcome
        if let processChannelLauncher {
            launchOutcome = await processChannelLauncher(plan.processLaunchPlan)
        } else if let ownedProcessChannelLauncher {
            do {
                launchOutcome = .acquired(
                    try await ownedProcessChannelLauncher.launch(
                        plan: plan.processLaunchPlan
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw DebuggerClientError.backendFailure(
                    "Persistent Xcode LLDB could not start under owned-process authority: \(error.localizedDescription)"
                )
            }
        } else {
            throw DebuggerClientError.backendUnavailable(
                Self.missingOwnedInfrastructureAuthorityReason
            )
        }

        let channel: any PersistentLLDBTargetlessProcessChannel
        switch launchOutcome {
        case .acquired(let acquired):
            channel = acquired
        case .failedAfterChild(let retainedChannel, let reason):
            let retainedAdapter = PersistentLLDBCLIAdapter(
                epoch: epoch,
                channel: retainedChannel,
                retainedProcess: retainedChannel,
                inboundNeedleProbe: inboundNeedleProbe
            )
            try await retirePreDispatchAdapterRequiringProof(
                retainedAdapter,
                unprovenMessage:
                    "The failed LLDB child could not be proven exited and reaped; restart MacScope before launching another target."
            )
            throw DebuggerClientError.backendFailure(
                "Persistent Xcode LLDB could not start: \(reason)"
            )
        }

        let adapterGeneration: UInt64 = 1
        let adapter = PersistentLLDBCLIAdapter(
            epoch: epoch,
            channel: channel,
            retainedProcess: channel,
            inboundNeedleProbe: inboundNeedleProbe
        )
        try await requirePreDispatchAuthority(retiringOnFailure: adapter)
        let preparer = PersistentLLDBProductionRequestPreparer()
        let coordinator = PersistentLLDBSessionCoordinator(
            epoch: epoch,
            executor: adapter,
            requestPreparer: preparer,
            launchedProcessEvidenceProvider: launchedProcessEvidenceProvider
        )
        let newSession = Session(
            adapter: adapter,
            coordinator: coordinator,
            preparer: preparer,
            runtimeModuleCollector: DebuggerRuntimeModuleInventoryCollector(),
            runtimeModuleToken: Data(SHA256.hash(data: Data(epoch.rawValue.uuidString.utf8))),
            adapterGeneration: adapterGeneration,
            logicalBreakpointOwnershipTagDigest: Self.logicalBreakpointOwnershipTagDigest(
                epoch: epoch,
                adapterGeneration: adapterGeneration
            ),
            executableName: plan.normalizedDisplayName,
            exactAttachedSessionEvidence: nil
        )
        try await requirePreDispatchAuthority(retiringOnFailure: adapter)
        session = newSession

        do {
            let exact = try await performExactLaunchAssumingOperationGateHeld(
                plan,
                in: newSession
            )
            return try await finish(
                Self.exactLaunchExecutionResult(exact),
                in: newSession,
                operationGateAlreadyHeld: true
            )
        } catch {
            let authoritative = await coordinator.reducerState
            switch authoritative.processPhase {
            case .running, .stopped:
                // Lifecycle observation outranks optional semantic projection. Publish the exact
                // reducer state so a launched target remains visible and controllable even when
                // breakpoint/detail recovery fails; never strand it behind a launch error.
                return try await finish(
                    PersistentLLDBSessionExecutionResult(
                        requestID: DebuggerRequestID(
                            epoch: authoritative.epoch,
                            sequence: authoritative.lastAdmittedRequestSequence
                        ),
                        reducerState: authoritative
                    ),
                    in: newSession,
                    operationGateAlreadyHeld: true
                )
            case .exited, .detached, .terminated:
                // A semantic launch failure can be followed by a terminal lifecycle observation.
                // Preserve that failure as an error instead of presenting a recovery-induced
                // terminal state as a successful launch. Terminal states never receive another
                // lifecycle command from this compatibility path.
                _ = try? await finish(
                    PersistentLLDBSessionExecutionResult(
                        requestID: DebuggerRequestID(
                            epoch: authoritative.epoch,
                            sequence: authoritative.lastAdmittedRequestSequence
                        ),
                        reducerState: authoritative
                    ),
                    in: newSession,
                    operationGateAlreadyHeld: true
                )
                throw map(error, operation: .launch)
            case .noTarget, .detaching, .invalidated:
                if authoritative.acceptedTargetAuthority == nil {
                    // The launch never accepted a target PID, so MacScope holds no target
                    // authority it could act on or protect: the only thing it owns is this LLDB
                    // child. A proven command-free exit and reap of that child is the terminal
                    // disposition MacScope can establish, so settle as resolved and admit a fresh
                    // launch. (Recording an unresolved blocker here wedged every later Launch
                    // Target until MacScope restarted.) An unproven retirement still records the
                    // blocker inside `finishResolvedRecovery`. Command-free retirement closes
                    // stdin and waits a bounded grace period for LLDB's own stdin-EOF exit, which
                    // kills the launched inferior, before it signals LLDB.
                    _ = await finishResolvedRecovery(
                        state: authoritative,
                        reason: .adapterInterruption,
                        in: newSession
                    )
                } else {
                    // Transitional detach and post-write transport uncertainty with an accepted
                    // target remain epoch-blocking states. Retire the adapter without issuing
                    // another lifecycle command; another launch remains prohibited until exact
                    // terminal proof exists.
                    _ = await recoverSessionAssumingOperationGateHeld(
                        for: .adapterInterruption,
                        in: newSession
                    )
                }
                throw map(error, operation: .launch)
            }
        }
    }

    /// Controller-owned exact local-process attach orchestration. Product callers may reach this
    /// only through an adapter/client whose capability report proves the complete app-global
    /// lease/owned-infrastructure/observation-policy graph is current and exact.
    func attach(
        _ request: DebuggerLocalAttachRequest
    ) async throws -> DebuggerSessionSnapshot {
        try requireActiveController()
        try Task.checkCancellation()
        try await awaitActivePoll()
        try requireActiveController()
        try Task.checkCancellation()
        await acquireOperationGate()
        defer { releaseOperationGate() }
        try requireActiveController()
        try Task.checkCancellation()

        try await requireNoLiveOrUnknownTargetBeforeLaunch()
        let exactAuthority = try requireExactAttachRuntimeAuthority()
        try await shutdownIdleSessionAssumingOperationGateHeld()
        try Task.checkCancellation()

        let epoch = DebuggerSessionEpoch()
        let authority = DebuggerSessionTargetAuthority(
            origin: .attached(request.selectedIdentity)
        )
        let reservation = try await exactAuthority.registry.reserve(
            ownerID: exactAuthority.ownerID,
            sessionEpoch: epoch,
            authority: authority
        )
        lastExactAttachReservationForTesting = reservation

        var adapterForPrePermitCleanup: PersistentLLDBCLIAdapter?
        var cleanupAlreadySettled = false
        do {
            try requireActiveController()
            try Task.checkCancellation()
            let plan = try PersistentLLDBTargetlessTransportPlan.make(
                toolchain: toolchain,
                environment: environment,
                fallbackWorkingDirectory: fallbackWorkingDirectory,
                timeout: commandTimeout
            )
            let construction = try await exactAuthority.factory.make(
                plan: plan,
                epoch: epoch,
                inboundNeedleProbe: inboundNeedleProbe
            )
            let transport: PersistentLLDBTargetlessTransport
            switch construction {
            case .acquired(let acquired):
                transport = acquired
                adapterForPrePermitCleanup = acquired.adapter
            case .unresolved(_, let retainedAdapter):
                let cleanup = await cleanupExactAttachBeforePermit(
                    reservation: reservation,
                    registry: exactAuthority.registry,
                    adapter: retainedAdapter
                )
                applyExactAttachPrePermitCleanupBlockers(
                    cleanup,
                    reservation: reservation,
                    adapter: retainedAdapter
                )
                cleanupAlreadySettled = true
                throw DebuggerClientError.backendUnavailable(
                    "The targetless LLDB helper could not be proven exited and reaped."
                )
            }
            try requireActiveController()

            guard transport.epoch == epoch,
                  transport.adapterGeneration > 0,
                  transport.attachWriteInterlock?.identity
                    == exactAuthority.interlockIdentity,
                  transport.localProcessEvidenceProvider != nil else {
                throw DebuggerClientError.backendUnavailable(
                    "The targetless LLDB helper did not retain the exact attach authority graph."
                )
            }
            let initialState = await transport.coordinator.reducerState
            guard initialState.epoch == epoch,
                  initialState.sessionCoordinate.epoch == epoch,
                  initialState.processPhase == .noTarget,
                  initialState.pendingRequest == nil,
                  initialState.acceptedTargetAuthority == nil,
                  initialState.observedProcessID == nil else {
                throw DebuggerClientError.backendUnavailable(
                    "The targetless LLDB helper was not in an exact no-target admission state."
                )
            }
            let adapterBinding = await transport.adapter.adapterInstanceBinding()
            guard adapterBinding.sessionEpoch == epoch,
                  adapterBinding.adapterGeneration == transport.adapterGeneration else {
                throw DebuggerClientError.backendUnavailable(
                    "The targetless LLDB helper lost its exact adapter binding."
                )
            }

            let policyResolution = await exactAuthority.policyProvider.snapshot(
                excluding: reservation
            )
            try requireActiveController()
            guard case .resolved(let policySnapshot) = policyResolution,
                  policySnapshot.attachWriteInterlockSnapshot.identity
                    == exactAuthority.interlockIdentity else {
                throw DebuggerClientError.backendUnavailable(
                    "Exact attach observation policy could not be captured after helper registration."
                )
            }

            let identityObserver = DebuggerLocalProcessIdentityObserver(
                provider: launchedProcessEvidenceProvider
            )
            let identityResolution = await identityObserver
                .revalidateAttachRequest(request, policy: policySnapshot.policy)
            try requireActiveController()
            guard case .resolved(let revalidatedIdentity) = identityResolution,
                  revalidatedIdentity == request.selectedIdentity,
                  revalidatedIdentity.identityDigest
                    == request.selectedIdentity.identityDigest else {
                throw DebuggerClientError.invalidState(
                    "The selected process identity changed before exact attach admission."
                )
            }

            try Task.checkCancellation()

            let permit = try await exactAuthority.registry.armExactAttach(
                reservation,
                admissionSession: initialState.sessionCoordinate,
                adapterGeneration: transport.adapterGeneration,
                attachWriteInterlockSnapshot:
                    policySnapshot.attachWriteInterlockSnapshot
            )
            let result: PersistentLLDBExactAttachTransactionResult
            do {
                // The permit is armed on the preceding statement. This must remain the immediate
                // next suspension point: no cancellation check, probe, or fallible preparation may
                // interpose between arming and the coordinator's one-shot claim.
                result = try await transport.coordinator.performExactAttachTransaction(
                    PersistentLLDBExactAttachTransactionInput(
                        request: request,
                        permit: permit
                    )
                )
            } catch let failure as PersistentLLDBExactAttachTransactionFailure {
                await settleExactAttachTransactionFailure(
                    failure,
                    reservation: reservation,
                    registry: exactAuthority.registry,
                    adapter: transport.adapter
                )
                cleanupAlreadySettled = true
                throw DebuggerClientError.backendFailure(
                    "Exact attach failed in the sealed LLDB transaction (\(failure.code.rawValue))."
                )
            }

            let provisional = makeExactAttachedSession(
                transport: transport,
                request: request,
                result: result
            )
            provisionalExactAttachSession = provisional

            do {
                let confirmationTask = Task.detached(priority: .userInitiated) {
                    try await exactAuthority.registry.confirmExactAttach(result)
                }
                let confirmation = try await withTaskCancellationHandler {
                    try await confirmationTask.value
                } onCancel: {
                    // A final attach write may already be committed. Registry confirmation is a
                    // mandatory settlement and cannot be truncated by caller cancellation.
                }
                guard confirmation.attachedSession == result.attachedSession,
                      result.attachedSession.permit == permit,
                      result.attachedSession.adapterInstanceBinding == adapterBinding,
                      result.attachedSession.hasValidBinding(),
                      result.attachedSession.establishedSession
                        == result.reducerState.sessionCoordinate,
                      result.reducerState.acceptedTargetAuthority == authority,
                      result.reducerState.observedProcessID == authority.processID,
                      result.requestID.epoch == epoch,
                      result.requestID.sequence
                        == result.reducerState.lastAdmittedRequestSequence else {
                    throw DebuggerClientError.backendFailure(
                        "Exact attach confirmation returned crossed session evidence."
                    )
                }
                try requireActiveController()
            } catch {
                session = provisional
                provisionalExactAttachSession = nil
                let recovery = await recoverSessionAssumingOperationGateHeld(
                    for: .adapterInterruption,
                    in: provisional
                )
                if !recovery.isResolved, unresolvedRecoveryBlocker == nil {
                    unresolvedRecoveryBlocker = UnresolvedRecoveryBlocker(
                        reason: .adapterInterruption,
                        authority: authority,
                        reobservation: nil
                    )
                }
                cleanupAlreadySettled = true
                throw DebuggerClientError.backendFailure(
                    "Exact attach confirmation failed; non-killing attached recovery was attempted."
                )
            }

            try requireActiveController()
            session = provisional
            provisionalExactAttachSession = nil
            cleanupAlreadySettled = true
            return try await finish(
                PersistentLLDBSessionExecutionResult(
                    requestID: result.requestID,
                    reducerState: result.reducerState
                ),
                in: provisional,
                operationGateAlreadyHeld: true
            )
        } catch {
            if !cleanupAlreadySettled {
                let cleanup = await cleanupExactAttachBeforePermit(
                    reservation: reservation,
                    registry: exactAuthority.registry,
                    adapter: adapterForPrePermitCleanup
                )
                applyExactAttachPrePermitCleanupBlockers(
                    cleanup,
                    reservation: reservation,
                    adapter: adapterForPrePermitCleanup
                )
            }
            throw error
        }
    }

    /// Test compatibility seam retained for existing focused orchestration coverage.
    func performDormantExactAttachForTesting(
        _ request: DebuggerLocalAttachRequest
    ) async throws -> DebuggerSessionSnapshot {
        try await attach(request)
    }

    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        _ = snapshot
        return try await runControl(.continue, commands: ["process continue"])
    }

    func runToCursor(
        _ request: DebuggerRunToCursorRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        _ = snapshot
        try await awaitActivePoll()
        let current = try requireSession(for: .runToCursor)
        await acquireOperationGate()
        var targetRecoveryRequired = false
        let cleaned: PersistentLLDBSessionExecutionResult
        do {
            try requireActiveController()
            try requireInstalledSessionIdentity(current)
            try Task.checkCancellation()
            // Re-read exact reducer authority only after the controller operation gate is held.
            let state = await current.coordinator.reducerState
            let inventory = try Self.requireRunToCursorAuthority(
                state,
                request: request,
                adapterGeneration: current.adapterGeneration
            )
            let runID = LLDBRunToCursorRunID(rawValue: UUID())!
            let ownerDigest = Self.runToCursorOwnerDigest(
                epoch: state.epoch,
                adapterGeneration: current.adapterGeneration
            )
            let prepared = try LLDBRunToCursorTransactionCodec().prepare(
                resolvedAddress: request.resolvedAddress,
                observedStopID: request.observedStopID,
                adapterGeneration: current.adapterGeneration,
                runtimeInventory: inventory,
                runID: runID,
                ownerDigest: ownerDigest
            )
            let reservation = try LLDBLogicalBreakpointTransactionReservation(
                helperPreparation: .proveInstallAndReprove,
                planPageCount: prepared.pages.count,
                receiptByteCountUpperBound: prepared.receiptByteCountUpperBound
            )
            let token = Self.runToCursorToken(
                runID: runID,
                epoch: state.epoch,
                adapterGeneration: current.adapterGeneration
            )
            let created = try await current.coordinator.createRunToCursorBinding(
                PersistentLLDBRunToCursorCreationInput(
                    prepared: prepared,
                    reservation: reservation,
                    token: token
                )
            )
            targetRecoveryRequired = true
            pendingRunToCursorBreakpoint = PendingRunToCursorBreakpoint(
                epoch: created.reducerState.epoch,
                receipt: created.receipt,
                ownerDigest: ownerDigest,
                token: token
            )
            // Only now may reducer admission tombstone the exact-stop mapping authority.
            let result = try await performAssumingOperationGateHeld(
                operation: .runToCursor,
                commands: ["process continue"],
                timeout: commandTimeout,
                responseProjection: .none,
                in: current
            )
            cleaned = try await cleanupRunToCursorBreakpointIfStopped(
                result,
                in: current,
                operationGateAlreadyHeld: true
            )
        } catch {
            let recoveryRequired = if let creationFailure = error
                as? PersistentLLDBRunToCursorCreationFailure {
                creationFailure.targetRecoveryRequired
            } else {
                targetRecoveryRequired
            }
            if recoveryRequired {
                // If the one-shot breakpoint identity cannot be proven, do not leave an unowned
                // mutation armed in the target. Terminate only through the correlated session.
                _ = await terminateAfterRunToCursorFailure(
                    in: current,
                    operationGateAlreadyHeld: true
                )
            }
            releaseOperationGate()
            if let creationFailure = error as? PersistentLLDBRunToCursorCreationFailure {
                throw map(
                    PersistentLLDBSessionCoordinatorFailure(code: creationFailure.code),
                    operation: .runToCursor
                )
            }
            throw map(error, operation: .runToCursor)
        }
        releaseOperationGate()
        // Presentation/detail finalization is outside the mutation-recovery catch and outside the
        // gate; the private breakpoint has already been proven absent at this point.
        return try await finish(cleaned, in: current)
    }

    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        _ = snapshot
        return try await runControl(.stepOver, commands: ["thread step-over"])
    }

    func stepInto(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        _ = snapshot
        return try await runControl(.stepInto, commands: ["thread step-in"])
    }

    func stepOut(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        _ = snapshot
        return try await runControl(.stepOut, commands: ["thread step-out"])
    }

    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        try await failClosedOnSessionFailure(.pause, recoveryReason: .adapterInterruption) {
            _ = snapshot
            try await awaitActivePoll()
            let current = try requireSession(for: .pause)
            let state = await current.coordinator.reducerState
            if case .stopped = state.processPhase {
                try requirePublicationAuthority(for: current, state: state)
                return DebuggerTransportSnapshotProjector.project(
                    state,
                    executableName: current.executableName
                )
            }
            guard case .running = state.processPhase else {
                throw DebuggerClientError.invalidState("Pause requires a running live debug process.")
            }
            let result = try await perform(
                .pause,
                commands: ["process interrupt"],
                in: current
            )
            let settled = try await settlePause(result, in: current)
            return try await finish(settled, in: current)
        }
    }

    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        _ = snapshot
        try await awaitActivePoll()
        let current = try requireSession(for: .terminate)
        let outcome = await recoverSession(for: .userRequestedSessionEnd, in: current)
        guard outcome.isResolved else {
            throw DebuggerClientError.backendUnavailable(
                "The debugger transport was retired without exact target disposition proof."
            )
        }
        try requirePublicationAuthority(
            for: current,
            state: await current.coordinator.reducerState
        )
        return outcome.snapshot
    }

    func detach(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        _ = snapshot
        try await awaitActivePoll()
        let current = try requireSession(for: .detach)
        let state = await current.coordinator.reducerState
        guard let authority = state.acceptedTargetAuthority,
              case .attached = authority.origin else {
            throw DebuggerClientError.invalidState(
                "Detach requires an attached-origin live debug process."
            )
        }
        let outcome = await recoverSession(for: .userRequestedSessionEnd, in: current)
        guard outcome.isResolved else {
            throw DebuggerClientError.backendUnavailable(
                "The debugger transport was retired without exact detach disposition proof."
            )
        }
        try requirePublicationAuthority(
            for: current,
            state: await current.coordinator.reducerState
        )
        return outcome.snapshot
    }

    func replaceBreakpoints(
        _ breakpoints: [DebuggerBreakpoint],
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        _ = snapshot
        try await awaitActivePoll()
        let current = try requireSession(for: .replaceBreakpoints)
        let state = await current.coordinator.reducerState
        if pendingRunToCursorBreakpoint?.epoch == state.epoch {
            throw DebuggerClientError.invalidState(
                "Breakpoint synchronization is deferred until Run to Cursor stops and removes its temporary breakpoint."
            )
        }
        guard state.observedProcessID != nil else {
            throw DebuggerClientError.invalidState(
                "Breakpoint mutation requires a live debug process."
            )
        }
        let desired = XcodeLLDBCommandLineAdapter.normalizedBreakpointDefinitions(breakpoints)
        let currentBreakpoints = state.breakpoints.map(Self.legacyBreakpoint)
        let commands = try XcodeLLDBCommandLineAdapter.makeBreakpointMutationCommands(
            from: currentBreakpoints,
            to: desired
        )
        guard !commands.isEmpty else {
            try requirePublicationAuthority(for: current, state: state)
            return DebuggerTransportSnapshotProjector.project(
                state,
                executableName: current.executableName
            )
        }
        let result = try await perform(
            .replaceBreakpoints,
            commands: commands,
            responseProjection: .breakpoints(
                desired.map(Self.transportBreakpoint),
                requireCreationProof: true
            ),
            in: current
        )
        return try await finish(result, in: current)
    }

    func reconcileLogicalBreakpoints(
        _ request: DebuggerLogicalBreakpointReconcileRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        _ = snapshot
        try await awaitActivePoll()
        let current = try requireSession(for: .reconcileLogicalBreakpoints)
        await acquireOperationGate()
        defer { releaseOperationGate() }

        do {
            try requireActiveController()
            try requireInstalledSessionIdentity(current)
            try Task.checkCancellation()
            // Re-read after the operation gate is held. No caller snapshot coordinate is trusted.
            let state = await current.coordinator.reducerState
            let inventory = try Self.requireLogicalBreakpointReconciliationAuthority(
                state,
                request: request,
                adapterGeneration: current.adapterGeneration
            )
            let transactionID = DebuggerBreakpointBindingTransactionID(rawValue: UUID())
            let prepared = try LLDBLogicalBreakpointTransactionCodec().prepare(
                request: request,
                transactionID: transactionID,
                adapterGeneration: current.adapterGeneration,
                runtimeInventory: inventory,
                ownershipTagDigest: current.logicalBreakpointOwnershipTagDigest
            )
            let reservation = try LLDBLogicalBreakpointTransactionReservation(
                helperPreparation: .proveInstallAndReprove,
                planPageCount: prepared.pages.count,
                receiptByteCountUpperBound: prepared.receiptByteCountUpperBound
            )
            let token = Self.logicalBreakpointTransactionToken(
                transactionID: transactionID,
                epoch: state.epoch,
                adapterGeneration: current.adapterGeneration
            )
            let result = try await current.coordinator
                .performLogicalBreakpointReconciliation(
                    PersistentLLDBLogicalBreakpointReconciliationInput(
                        observation: request.observation,
                        prepared: prepared,
                        reservation: reservation,
                        token: token
                    )
                )
            return DebuggerTransportSnapshotProjector.project(
                result.reducerState,
                executableName: current.executableName
            )
        } catch let failure as PersistentLLDBLogicalBreakpointCallbackDrainFailure {
            await terminateAfterPartialMutationFailureAssumingOperationGateHeld(
                operation: .reconcileLogicalBreakpoints,
                in: current
            )
            throw map(failure, operation: .reconcileLogicalBreakpoints)
        } catch let failure as PersistentLLDBLogicalBreakpointReconciliationFailure {
            let recovery = Self.logicalBreakpointFailureRecovery(
                classification: failure.classification,
                sessionAuthorityLost: failure.sessionDisposition == .invalidateAndShutdown
            )
            switch recovery {
            case .boundedTargetRecovery:
                // The coordinator deliberately throws before invalidating the stopped reducer.
                // Recovery therefore runs under the same controller gate and attempts the bounded
                // kill/poll sequence. If the adapter was also lost, that attempt fails closed into
                // invalidation; a validated receipt was committed first so positive IDs survive.
                await terminateAfterPartialMutationFailureAssumingOperationGateHeld(
                    operation: .reconcileLogicalBreakpoints,
                    in: current
                )
            case .invalidateSessionAndShutdownAdapter:
                await invalidateLogicalBreakpointSessionAfterAuthorityLossAssumingOperationGateHeld(
                    in: current
                )
            case .none:
                break
            }
            throw map(failure, operation: .reconcileLogicalBreakpoints)
        } catch {
            throw map(error, operation: .reconcileLogicalBreakpoints)
        }
    }

    func writeRegister(
        _ request: DebuggerRegisterWriteRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        try await failClosedOnSessionFailure(.writeRegister) {
            _ = snapshot
            return try await performStoppedDataOperation(
                .writeRegister,
                commands: [XcodeLLDBCommandLineAdapter.makeRegisterWriteCommand(for: request)]
                    + Self.stoppedRefreshCommands
            )
        }
    }

    func readMemory(
        _ request: DebuggerMemoryReadRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        try await failClosedOnSessionFailure(.readMemory) {
            _ = snapshot
            return try await performStoppedDataOperation(
                .readMemory,
                commands: Self.stoppedRefreshCommands + [
                    XcodeLLDBCommandLineAdapter.makeMemoryReadCommand(for: request)
                ]
            )
        }
    }

    func updateWatchpoints(
        _ request: DebuggerWatchpointRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        try request.validate()
        return try await failClosedOnSessionFailure(.updateWatchpoints) {
            try await awaitActivePoll()
            let current = try await requireStoppedSession(for: .updateWatchpoints)
            let state = await current.coordinator.reducerState
            guard snapshot.transportSessionCoordinate == state.sessionCoordinate,
                  snapshot.transportStopCoordinate == state.stopCoordinate,
                  let pid = state.observedProcessID,
                  case .available(let inventory) = state.runtimeModuleInventoryState.authority,
                  inventory.observedStopID > 0 else {
                throw DebuggerClientError.invalidState("Refresh the paused session before changing watchpoints.")
            }
            let command = try LLDBWatchpointProgram.command(for: request, processID: pid, stopID: inventory.observedStopID)
            let result = try await perform(
                .updateWatchpoints,
                commands: LLDBWatchpointProgram.installCommands + [command],
                responseProjection: .watchpoints,
                in: current
            )
            return try await finish(result, in: current)
        }
    }

    func writeMemory(
        _ request: DebuggerMemoryWriteRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        try await failClosedOnSessionFailure(.writeMemory) {
            _ = snapshot
            return try await performStoppedDataOperation(
                .writeMemory,
                commands: [
                    XcodeLLDBCommandLineAdapter.makeMemoryWriteCommand(for: request),
                    XcodeLLDBCommandLineAdapter.makeMemoryWriteReadBackCommand(for: request),
                ] + Self.stoppedRefreshCommands,
                responseProjection: .memoryWriteReadback(
                    address: request.address,
                    bytes: request.bytes
                )
            )
        }
    }

    func evaluateExpression(
        _ request: DebuggerExpressionRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerExpressionResult {
        try await failClosedOnSessionFailure(.evaluateExpression) {
            _ = snapshot
            try await awaitActivePoll()
            let current = try await requireStoppedSession(for: .evaluateExpression)
            let result = try await perform(
                .evaluateExpression,
                commands: [XcodeLLDBCommandLineAdapter.makeExpressionCommand(for: request)],
                responseProjection: .expression,
                in: current
            )
            guard let evaluation = result.reducerState.expressionEvaluation else {
                throw DebuggerClientError.backendFailure(
                    "Expression Evaluation returned no typed value."
                )
            }
            // Expression evaluation can load or unload images. The reducer tombstones mapping on
            // admission, so refresh the exact same stopped authority before returning the value.
            do {
                let refreshed = try await refreshRuntimeModules(in: current)
                return DebuggerExpressionResult(
                    value: evaluation.displayValue,
                    type: evaluation.typeName,
                    refreshedSnapshot: DebuggerTransportSnapshotProjector.project(
                        refreshed.reducerState,
                        executableName: current.executableName
                    )
                )
            } catch {
                let authoritativeState = await current.coordinator.reducerState
                if let preserved = Self.expressionResultAfterRuntimeModuleRefreshFailure(
                    value: evaluation.displayValue,
                    type: evaluation.typeName,
                    authoritativeState: authoritativeState,
                    executableName: current.executableName
                ) {
                    return preserved
                }
                if authoritativeState.isInvalidated {
                    await shutdownInvalidatedSession(in: current)
                }
                throw map(error, operation: .refreshRuntimeModules)
            }
        }
    }

    func expandVariableChildren(
        _ request: DebuggerVariableExpansionRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        try await failClosedOnSessionFailure(.expandVariableChildren) {
            _ = snapshot
            try await awaitActivePoll()
            let current = try await requireStoppedSession(for: .expandVariableChildren)
            let state = await current.coordinator.reducerState
            let plan = try Self.variableChildExpansionPlan(
                request: request,
                state: state,
                adapterGeneration: current.adapterGeneration
            )
            let result = try await perform(
                .expandVariableChildren,
                commands: plan.commands,
                responseProjection: .variableChildren(plan.expectation, request),
                variableExpansionRequest: request,
                in: current
            )
            return try await finish(result, in: current)
        }
    }

    func selectThread(
        _ request: DebuggerThreadSelectionRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        try await failClosedOnSessionFailure(.selectThread) {
            _ = snapshot
            // LLDB pins the interpreter's execution context for the whole outer `script` command
            // that carries one exchange (see `PersistentLLDBCLIAdapter.encodedWirePayload`). In
            // the exchange that runs `thread select N`, `thread list` reports thread N selected,
            // but `thread backtrace`, `register read` and `memory read $sp` still read the thread
            // selected when the exchange began. Tier 2k C6: that paired thread N's identity with
            // the stop thread's frames, the variable extractor's exact frame check rejected it,
            // and the coordinator failed. The selection therefore commits alone; the stopped
            // refresh runs in the next exchange, whose pinned context is the new selection.
            _ = try await performStoppedDataOperation(
                .selectThread,
                commands: [XcodeLLDBCommandLineAdapter.makeThreadSelectCommand(for: request)],
                responseProjection: .none
            )
            let refreshed = try await performStoppedDataOperation(
                .refreshSnapshot,
                commands: Self.stoppedRefreshCommands
            )
            // Selection must commit before the extractor can bind a receipt to the newly selected
            // thread's backend TID, frame zero, and PC. Never predict those coordinates from the
            // formerly selected thread.
            return try await refreshSnapshot(from: refreshed)
        }
    }

    func selectFrame(
        _ request: DebuggerFrameSelectionRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        try await failClosedOnSessionFailure(.selectFrame) {
            _ = snapshot
            try await awaitActivePoll()
            let current = try await requireStoppedSession(for: .selectFrame)
            let state = await current.coordinator.reducerState
            guard case .available(let frames) = state.stoppedData?.frames,
                  frames.contains(where: { $0.identifier == request.index }) else {
                throw DebuggerClientError.invalidState(
                    "Frame #\(request.index) is not present in the current exact stop."
                )
            }
            let variablePlan = try Self.variableRefreshPlan(
                state: state,
                adapterGeneration: current.adapterGeneration,
                selectedFrameID: request.index
            )
            // `frame select` has the same pinned-context hazard as `thread select` (see
            // `selectThread`): inside the exchange that runs it, `register read`, `memory read
            // $sp` and the variable extractor still see the frame selected when the exchange
            // began. So the selection commits in its own exchange and the inspection runs in
            // the next one. Helper retention: the variable extractor is installed and proven
            // before the selection dispatches (a helper failure never follows a frame mutation)
            // and the gate stays held across all three steps, so no other writer can run between
            // installation and extraction. The interpreter keeps the installed helper across
            // exchanges, so the inspection exchange does not reinstall it.
            let result = try await performFrameSelectionSequence(
                selectCommand: XcodeLLDBCommandLineAdapter.makeFrameSelectCommand(for: request),
                inspectionCommands: Self.stoppedRefreshCommands + (variablePlan?.commands ?? []),
                inspectionProjection: variablePlan.map {
                    .stoppedDataWithVariables($0.expectation)
                } ?? .stoppedData,
                installsVariableExtractor: variablePlan != nil,
                in: current
            )
            return try await finish(result, in: current)
        }
    }

    /// One gate hold: [helper install + proof] → `frame select` alone → inspection. Every failure
    /// settles through the same path as `perform`, so a failed inspection after a committed
    /// selection is a partial frame-selection mutation, while a helper failure is not.
    private func performFrameSelectionSequence(
        selectCommand: String,
        inspectionCommands: [String],
        inspectionProjection: PersistentLLDBProductionRequestPreparer.ResponseProjection,
        installsVariableExtractor: Bool,
        in current: Session
    ) async throws -> PersistentLLDBSessionExecutionResult {
        await acquireOperationGate()
        do {
            try requireActiveController()
            try requireInstalledSessionIdentity(current)
            try Task.checkCancellation()
            if installsVariableExtractor {
                try await installVariableExtractorAssumingOperationGateHeld(
                    in: current,
                    timeout: commandTimeout
                )
            }
            _ = try await performAssumingOperationGateHeld(
                operation: .selectFrame,
                commands: [selectCommand],
                timeout: commandTimeout,
                responseProjection: .none,
                installsVariableExtractor: false,
                in: current
            )
            let result = try await performAssumingOperationGateHeld(
                operation: .selectFrame,
                commands: inspectionCommands,
                timeout: commandTimeout,
                responseProjection: inspectionProjection,
                installsVariableExtractor: false,
                in: current
            )
            releaseOperationGate()
            return result
        } catch {
            return try await settleFailedExchangeAssumingOperationGateHeld(
                error,
                operation: .selectFrame,
                in: current
            )
        }
    }

    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        try await failClosedOnSessionFailure(.refreshSnapshot) {
            _ = snapshot
            try await awaitActivePoll()
            let current = try await requireStoppedSession(for: .refreshSnapshot)
            let state = await current.coordinator.reducerState
            let variablePlan = try Self.variableRefreshPlan(
                state: state,
                adapterGeneration: current.adapterGeneration
            )
            let result = try await perform(
                .refreshSnapshot,
                commands: Self.stoppedRefreshCommands + (variablePlan?.commands ?? []),
                responseProjection: variablePlan.map {
                    .stoppedDataWithVariables($0.expectation)
                } ?? .stoppedData,
                in: current
            )
            return try await finish(result, in: current, forceRuntimeModuleRefresh: true)
        }
    }

    private struct VariableRefreshPlan {
        let commands: [String]
        let expectation: PersistentLLDBProductionRequestPreparer.VariableRefreshExpectation
    }

    private nonisolated static func variableChildExpansionPlan(
        request: DebuggerVariableExpansionRequest,
        state: DebuggerReducerState,
        adapterGeneration: UInt64
    ) throws -> VariableRefreshPlan {
        guard let base = try variableRefreshPlan(
            state: state,
            adapterGeneration: adapterGeneration
        ),
              PersistentLLDBProductionRequestPreparer
                .isValidVariableChildRequestShape(request),
              request.coordinate == base.expectation.coordinate,
              variableTreeContains(request, in: state) else {
            throw DebuggerClientError.invalidState(
                "Variable child expansion requires a current exact stopped-frame variable."
            )
        }
        let program = LLDBVariableExtractorProgram.current
        let childCommand = try program.childSnapshotCommand(
            token: base.expectation.token,
            expectedProcessID: base.expectation.processID,
            expectedStopID: base.expectation.observedStopID,
            threadID: base.expectation.threadID,
            frameIndex: base.expectation.frameIndex,
            programCounter: base.expectation.programCounter,
            pathComponents: request.pathComponents
        )
        return VariableRefreshPlan(
            commands: [childCommand],
            expectation: base.expectation
        )
    }

    private nonisolated static func variableTreeContains(
        _ request: DebuggerVariableExpansionRequest,
        in state: DebuggerReducerState
    ) -> Bool {
        guard let stoppedData = state.stoppedData,
              case .available(let variables) = stoppedData.variables else { return false }
        return variables.contains { snapshot in
            snapshot.coordinate == request.coordinate
                && snapshot.scope.rawValue == request.pathComponents.first
                && variableTreeContains(request, in: snapshot.nodes)
        }
    }

    private nonisolated static func variableTreeContains(
        _ request: DebuggerVariableExpansionRequest,
        in nodes: [DebuggerVariableNode]
    ) -> Bool {
        nodes.contains { node in
            let canRequestExpansion: Bool
            switch node.childExpansion {
            case .notLoaded, .failed:
                canRequestExpansion = true
            case .loading, .loaded:
                canRequestExpansion = false
            }
            return (node.id == request.token
                && node.pathComponents == request.pathComponents
                && node.isExpandable
                && canRequestExpansion)
                || variableTreeContains(request, in: node.children)
        }
    }

    private nonisolated static func variableRefreshPlan(
        state: DebuggerReducerState,
        adapterGeneration: UInt64,
        selectedFrameID overrideFrameID: Int? = nil
    ) throws -> VariableRefreshPlan? {
        guard adapterGeneration > 0,
              !state.isInvalidated,
              case .stopped(let processID, _) = state.processPhase,
              processID > 0,
              state.observedProcessID == processID,
              let stop = state.stopCoordinate,
              let authority = state.acceptedTargetAuthority,
              authority.processID == processID,
              let stoppedData = state.stoppedData,
              case .available(let threads) = stoppedData.threads,
              case .available(let frames) = stoppedData.frames,
              let selectedThreadID = stoppedData.selectedThreadID,
              let thread = threads.first(where: { $0.identifier == selectedThreadID }),
              let threadID = thread.threadID,
              let threadIdentity = DebuggerThreadIdentity(index: thread.identifier, tid: threadID),
              let selectedFrameID = overrideFrameID ?? stoppedData.selectedFrameID,
              let frame = frames.first(where: { $0.identifier == selectedFrameID }),
              let frameIdentity = DebuggerFrameIdentity(
                thread: threadIdentity,
                frameIndex: frame.identifier,
                programCounter: frame.address,
                canonicalFunctionName: frame.functionName.isEmpty ? nil : frame.functionName
              ),
              let coordinate = DebuggerInspectionCoordinate(
                stop: stop,
                targetAuthority: authority,
                thread: threadIdentity,
                frame: frameIdentity
              ),
              case .available(let inventory) = state.runtimeModuleInventoryState.authority,
              inventory.stop == stop,
              inventory.processID == processID,
              inventory.observedStopID > 0,
              let frameIndex = UInt32(exactly: frame.identifier) else { return nil }

        let tokenMaterial = "\(stop.session.epoch.rawValue.uuidString.lowercased()):\(stop.session.lifecycleRevision.rawValue):\(stop.stopRevision.rawValue):\(adapterGeneration):\(processID):\(inventory.observedStopID):\(threadID):\(frame.identifier):\(frame.address)"
        let token = Data(SHA256.hash(data: Data(tokenMaterial.utf8)))
        let expectation = PersistentLLDBProductionRequestPreparer.VariableRefreshExpectation(
            token: token,
            coordinate: coordinate,
            processID: processID,
            observedStopID: inventory.observedStopID,
            threadID: threadID,
            frameIndex: frameIndex,
            programCounter: frame.address
        )
        let program = LLDBVariableExtractorProgram.current
        let snapshotCommand = try program.snapshotCommand(
            token: token,
            expectedProcessID: processID,
            expectedStopID: inventory.observedStopID,
            threadID: threadID,
            frameIndex: frameIndex,
            programCounter: frame.address
        )
        return VariableRefreshPlan(
            commands: [snapshotCommand],
            expectation: expectation
        )
    }

    func pollProcessStatus(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        try await failClosedOnSessionFailure(
            .pollProcessStatus,
            recoveryReason: .adapterInterruption
        ) {
            _ = snapshot
            let current = try requireSession(for: .pollProcessStatus)
            if let activePoll {
                return try await finish(try await activePoll.value, in: current)
            }

            let state = await current.coordinator.reducerState
            guard case .running = state.processPhase else {
                try requirePublicationAuthority(for: current, state: state)
                return DebuggerTransportSnapshotProjector.project(
                    state,
                    executableName: current.executableName
                )
            }
            let currentPollTimeout = Self.resolvedPollTimeout(
                for: commandTimeout,
                hasLogicalCallbackAuthority:
                    !state.breakpointBindingState.ownedLocations.isEmpty
                    && !state.breakpointBindingState.isInvalidated
            )
            // The shared active-poll task owns the operation gate through exact private-breakpoint
            // cleanup. No waiter may observe a stopped state and start another mutation in the gap.
            let task = Task {
                await self.acquireOperationGate()
                do {
                    let result = try await self.performAssumingOperationGateHeld(
                        operation: .pollProcessStatus,
                        commands: [],
                        timeout: currentPollTimeout,
                        responseProjection: .none,
                        in: current
                    )
                    let cleaned = try await self.cleanupRunToCursorBreakpointIfStopped(
                        result,
                        in: current,
                        operationGateAlreadyHeld: true
                    )
                    self.releaseOperationGate()
                    return cleaned
                } catch {
                    if self.pendingRunToCursorBreakpoint != nil {
                        _ = await self.terminateAfterRunToCursorFailure(
                            in: current,
                            operationGateAlreadyHeld: true
                        )
                    } else if error is PersistentLLDBLogicalBreakpointCallbackDrainFailure {
                        await self.terminateAfterPartialMutationFailureAssumingOperationGateHeld(
                            operation: .pollProcessStatus,
                            in: current
                        )
                    }
                    self.releaseOperationGate()
                    throw error
                }
            }
            activePoll = task
            do {
                let result = try await task.value
                activePoll = nil
                return try await finish(result, in: current)
            } catch {
                activePoll = nil
                await current.preparer.discard(operation: .pollProcessStatus)
                throw map(error, operation: .pollProcessStatus)
            }
        }
    }

    /// Continue and the steps settle failures like the stopped-state operations (#486, §4.86b):
    /// a preflight rejection passes through, and any other failure retires the session through
    /// the origin-aware recovery boundary so LLDB, debugserver and the debuggee are never left
    /// behind a "No live debug process" panel.
    private func runControl(
        _ operation: DebuggerOperation,
        commands: [String]
    ) async throws -> DebuggerSessionSnapshot {
        try await failClosedOnSessionFailure(operation, recoveryReason: .adapterInterruption) {
            try await awaitActivePoll()
            let current = try requireSession(for: operation)
            let state = await current.coordinator.reducerState
            guard case .stopped = state.processPhase, state.stopCoordinate != nil else {
                throw DebuggerClientError.invalidState(
                    "\(operation.displayLabel) requires a paused live debug process."
                )
            }
            let result = try await perform(operation, commands: commands, in: current)
            return try await finish(result, in: current)
        }
    }

    /// The panel treats every failure other than a preflight rejection (`invalidState`,
    /// `invalidConfiguration`, `unsupportedOperation`) as the end of the live session and shows
    /// "No live debug process". Never leave the retained LLDB adapter, its debugserver, or the
    /// session's own debuggee alive behind such a failure (Tier 2k C6: a thread selection that
    /// failed the coordinator orphaned all three until MacScope quit). A rejection that left one
    /// exact stopped session intact is reported as `invalidState`, which keeps the session live in
    /// the panel. Any other failure of a stopped-state operation runs the one origin-aware
    /// recovery boundary (terminate
    /// the exact launched target or detach the exact attached one, then command-free adapter
    /// retirement, #384) for the session it ran against, which also clears the session so Launch
    /// Target is admitted again (#420). The caller receives a typed backend failure.
    private func failClosedOnSessionFailure<T>(
        _ operation: DebuggerOperation,
        recoveryReason: DebuggerRecoveryReason? = nil,
        _ body: () async throws -> T
    ) async throws -> T {
        let current = session
        do {
            return try await body()
        } catch is CancellationError {
            // Supersession is not a session failure; the coordinator already settled any
            // request that may have been written.
            throw CancellationError()
        } catch {
            if let clientError = error as? DebuggerClientError,
               Self.isPreflightRejection(clientError) {
                throw error
            }
            if let current, installedSessionMatches(current) {
                let state = await current.coordinator.reducerState
                if installedSessionMatches(current),
                   Self.stoppedSessionSurvives(error, state: state) {
                    // LLDB rejected this one request but the coordinator kept an exact, coherent
                    // stopped session (for example an unmapped memory read or an expression
                    // error). Keep it live and visible so the user can continue or end it; a
                    // backend failure here would make the panel drop a session that still owns
                    // LLDB, debugserver and the target.
                    throw DebuggerClientError.invalidState(
                        "\(operation.displayLabel) was rejected by LLDB; the stopped debug session is unchanged."
                    )
                }
                _ = await recoverSession(
                    for: recoveryReason ?? .partialMutation(operation: operation),
                    in: current
                )
            }
            throw map(error, operation: operation)
        }
    }

    /// A correlated per-request rejection leaves the session usable only while the reducer still
    /// holds one exact, uninvalidated stopped authority with nothing pending. Invalidation,
    /// correlation loss, adapter failure, an observed-process mismatch or any non-coordinator
    /// error is never survivable.
    nonisolated static func stoppedSessionSurvives(
        _ error: Error,
        state: DebuggerReducerState
    ) -> Bool {
        guard let failure = error as? PersistentLLDBSessionCoordinatorFailure else { return false }
        switch failure.code {
        case .responseProjectionFailed, .requestPreparationFailed, .admissionRejected,
             .preparedRequestMismatch:
            break
        case .requestSequenceExhausted, .eventSequenceExhausted, .responseCorrelationMismatch,
             .invalidObservedProcess, .adapterCancelled, .adapterFailedBeforeWrite,
             .adapterInvalidated, .reducerRejected:
            return false
        }
        guard !state.isInvalidated,
              state.pendingRequest == nil,
              case .stopped(let processID, _) = state.processPhase,
              processID > 0,
              state.observedProcessID == processID,
              state.targetDisposition == .stopped(processID: processID),
              let authority = state.acceptedTargetAuthority,
              authority.processID == processID else {
            return false
        }
        return true
    }

    nonisolated static func isPreflightRejection(_ error: DebuggerClientError) -> Bool {
        switch error {
        case .invalidState, .invalidConfiguration, .unsupportedOperation:
            true
        case .backendUnavailable, .backendFailure:
            false
        }
    }

    private func performStoppedDataOperation(
        _ operation: DebuggerOperation,
        commands: [String],
        responseProjection: PersistentLLDBProductionRequestPreparer.ResponseProjection = .stoppedData
    ) async throws -> DebuggerSessionSnapshot {
        try await awaitActivePoll()
        let current = try await requireStoppedSession(for: operation)
        let result = try await perform(
            operation,
            commands: commands,
            responseProjection: responseProjection,
            in: current
        )
        return try await finish(result, in: current)
    }

    private func perform(
        _ operation: DebuggerOperation,
        commands: [String],
        timeout: Duration? = nil,
        responseProjection: PersistentLLDBProductionRequestPreparer.ResponseProjection = .none,
        variableExpansionRequest: DebuggerVariableExpansionRequest? = nil,
        in current: Session
    ) async throws -> PersistentLLDBSessionExecutionResult {
        await acquireOperationGate()
        do {
            try requireActiveController()
            try requireInstalledSessionIdentity(current)
            try Task.checkCancellation()
            let result = try await performAssumingOperationGateHeld(
                operation: operation,
                commands: commands,
                timeout: timeout ?? commandTimeout,
                responseProjection: responseProjection,
                variableExpansionRequest: variableExpansionRequest,
                in: current
            )
            releaseOperationGate()
            return result
        } catch {
            return try await settleFailedExchangeAssumingOperationGateHeld(
                error,
                operation: operation,
                in: current
            )
        }
    }

    /// The failure half of `perform`. Releases the operation gate on every path.
    private func settleFailedExchangeAssumingOperationGateHeld(
        _ error: Error,
        operation: DebuggerOperation,
        in current: Session
    ) async throws -> PersistentLLDBSessionExecutionResult {
        precondition(operationGateIsLocked)
        if error is PersistentLLDBLogicalBreakpointCallbackDrainFailure {
            await terminateAfterPartialMutationFailureAssumingOperationGateHeld(
                operation: operation,
                in: current
            )
            await current.preparer.discard(operation: operation)
            await current.preparer.discardOutstandingResponses()
            releaseOperationGate()
            throw error
        }
        let failedIndex: Int?
        if let failure = error as? PersistentLLDBSessionCoordinatorFailure,
           let requestID = failure.requestID {
            failedIndex = await current.preparer.takeFailedSemanticCommandIndex(
                for: requestID
            )
        } else {
            failedIndex = nil
        }
        await current.preparer.discard(operation: operation)
        await current.preparer.discardOutstandingResponses()
        if failedIndex != nil,
           Self.requiresFailClosedPartialMutationRecovery(operation) {
            await terminateAfterPartialMutationFailureAssumingOperationGateHeld(
                operation: operation,
                in: current
            )
        }
        let authoritativeState = await current.coordinator.reducerState
        if Self.canReturnAuthoritativeLifecycleFailure(operation),
           Self.failureCarriesAuthoritativeStatus(error),
           !authoritativeState.isInvalidated,
           authoritativeState.targetDisposition != .unknown,
           authoritativeState.processPhase != .noTarget {
            let requestID = (error as? PersistentLLDBSessionCoordinatorFailure)?.requestID
                ?? DebuggerRequestID(epoch: authoritativeState.epoch, sequence: 0)
            releaseOperationGate()
            return PersistentLLDBSessionExecutionResult(
                requestID: requestID,
                reducerState: authoritativeState
            )
        }
        releaseOperationGate()
        throw error
    }

    private func performExactLaunchAssumingOperationGateHeld(
        _ plan: DebuggerLLDBSealedLaunchPlan,
        in current: Session
    ) async throws -> PersistentLLDBExactLaunchTransactionResult {
        precondition(operationGateIsLocked)
        try requireInstalledSessionIdentity(current)
        // The launch owner already holds the controller gate across sealing, child installation,
        // exact establishment, and final projection. No nested acquisition can deadlock or allow a
        // reentrant second launch to retire this in-flight adapter.
        let state = await current.coordinator.reducerState
        try requireCommandAdmissionAuthority(current)
        try Task.checkCancellation()
        return try await current.coordinator.performExactLaunchTransaction(
            PersistentLLDBExactLaunchTransactionInput(
                plan: plan,
                expectedSession: state.sessionCoordinate,
                adapterGeneration: current.adapterGeneration
            )
        )
    }

    private func performAssumingOperationGateHeld(
        operation: DebuggerOperation,
        commands: [String],
        timeout: Duration,
        responseProjection: PersistentLLDBProductionRequestPreparer.ResponseProjection,
        variableExpansionRequest: DebuggerVariableExpansionRequest? = nil,
        installsVariableExtractor: Bool = true,
        in current: Session
    ) async throws -> PersistentLLDBSessionExecutionResult {
        precondition(operationGateIsLocked)
        try requireCommandAdmissionAuthority(current)
        switch responseProjection {
        case .stoppedDataWithVariables, .variableChildren:
            // A caller that already installed and proved the helper under this same gate hold
            // (frame selection) passes `false`; every other caller reinstalls here.
            if installsVariableExtractor {
                try await installVariableExtractorAssumingOperationGateHeld(
                    in: current,
                    timeout: timeout
                )
            }
        default:
            break
        }
        let state = await current.coordinator.reducerState
        let requiredStop = operation.requiresStopCoordinate ? state.stopCoordinate : nil
        await current.preparer.discard(operation: operation)
        try await current.preparer.install(
            operation: operation,
            commands: commands,
            timeout: timeout,
            responseProjection: responseProjection
        )
        try requireCommandAdmissionAuthority(current)
        try Task.checkCancellation()
        return try await current.coordinator.perform(
            operation,
            expectedSession: state.sessionCoordinate,
            requiredStop: requiredStop,
            variableExpansionRequest: variableExpansionRequest
        )
    }

    /// Each installation command needs its own physical exchange: the adapter's complete
    /// base64-wrapped request (not just an individual semantic command) is capped at 4 KiB.
    /// Hold the operation gate throughout so frame selection and extraction cannot interleave
    /// with another writer. Reinstalling also avoids trusting stale interpreter globals.
    private func installVariableExtractorAssumingOperationGateHeld(
        in current: Session,
        timeout: Duration
    ) async throws {
        precondition(operationGateIsLocked)
        let program = LLDBVariableExtractorProgram.current
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        for command in Self.variableExtractorInstallationCommands(program: program) {
            try Task.checkCancellation()
            try requireCommandAdmissionAuthority(current)
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw PersistentLLDBProductionControllerError.variableExtractorInstallationTimedOut
            }
            do {
                _ = try await performAssumingOperationGateHeld(
                    operation: .refreshSnapshot,
                    commands: [command],
                    timeout: remaining,
                    responseProjection: .none,
                    in: current
                )
            } catch {
                // This index belongs to helper installation, before the enclosing operation's
                // primary command dispatch. Do not let that caller classify it as a partial
                // frame/thread mutation and destroy or detach an otherwise stopped target.
                if let failure = error as? PersistentLLDBSessionCoordinatorFailure,
                   let requestID = failure.requestID {
                    _ = await current.preparer.takeFailedSemanticCommandIndex(for: requestID)
                }
                throw error
            }
        }
    }

    nonisolated static func variableExtractorInstallationCommands(
        program: LLDBVariableExtractorProgram = .current
    ) -> [String] {
        program.installChunkCommands + [program.installFinalizeCommand, program.installedProofCommand]
    }

    private static func requiresFailClosedPartialMutationRecovery(
        _ operation: DebuggerOperation
    ) -> Bool {
        switch operation {
        case .launch, .runToCursor, .replaceBreakpoints, .reconcileLogicalBreakpoints,
             .writeRegister, .writeMemory, .updateWatchpoints, .selectThread, .selectFrame:
            true
        case .attach, .continue, .stepOver, .stepInto, .stepOut, .pause, .detach, .terminate,
             .readMemory, .evaluateExpression, .expandVariableChildren, .refreshSnapshot,
             .refreshRuntimeModules, .pollProcessStatus:
            false
        }
    }

    /// Only a failure that came back with a correlated response carries an authoritative status
    /// segment. An adapter that never took the request, or lost it after the write, proves nothing
    /// about the target: returning the reducer's old stopped state there would leave a session
    /// over a dead adapter (and its debugserver and debuggee) looking alive (§4.86b).
    nonisolated static func failureCarriesAuthoritativeStatus(_ error: Error) -> Bool {
        guard let failure = error as? PersistentLLDBSessionCoordinatorFailure else { return true }
        switch failure.code {
        case .adapterFailedBeforeWrite, .adapterInvalidated, .responseCorrelationMismatch:
            return false
        case .adapterCancelled, .responseProjectionFailed, .requestPreparationFailed,
             .admissionRejected,
             .preparedRequestMismatch, .requestSequenceExhausted, .eventSequenceExhausted,
             .invalidObservedProcess, .reducerRejected:
            return true
        }
    }

    /// A failed lifecycle command can still yield authoritative target state from the isolated
    /// status segment. Preserve that state (and its reducer diagnostic) instead of making the UI
    /// replace a known running/stopped/exited target with a generic unavailable snapshot.
    private static func canReturnAuthoritativeLifecycleFailure(
        _ operation: DebuggerOperation
    ) -> Bool {
        switch operation {
        case .continue, .stepOver, .stepInto, .stepOut, .pause, .terminate:
            true
        case .launch, .attach, .detach, .runToCursor, .replaceBreakpoints,
             .reconcileLogicalBreakpoints, .writeRegister,
             .readMemory, .writeMemory, .updateWatchpoints, .evaluateExpression, .expandVariableChildren,
             .selectThread, .selectFrame, .refreshSnapshot, .refreshRuntimeModules,
             .pollProcessStatus:
            false
        }
    }

    private func recoverSession(
        for reason: DebuggerRecoveryReason,
        in current: Session
    ) async -> RecoveryOutcome {
        await acquireOperationGate()
        let outcome = await recoverSessionAssumingOperationGateHeld(for: reason, in: current)
        releaseOperationGate()
        return outcome
    }

    /// The only controller boundary allowed to choose a target-disposition action. It re-reads the
    /// reducer after acquiring the controller gate, evaluates the origin-aware policy exactly once,
    /// and never selects a second target command after any request may have been written.
    private func recoverSessionAssumingOperationGateHeld(
        for reason: DebuggerRecoveryReason,
        in current: Session
    ) async -> RecoveryOutcome {
        precondition(operationGateIsLocked)
        let state = await current.coordinator.reducerState
        guard installedSessionMatches(current) else {
            return RecoveryOutcome(
                snapshot: DebuggerTransportSnapshotProjector.project(
                    state,
                    executableName: current.executableName
                ),
                isResolved: true
            )
        }
        let decision = DebuggerOriginAwareRecoveryPolicy(reason: reason).decision(for: state)

        switch decision {
        case .terminateLaunched(let authority):
            do {
                let termination = try await performAssumingOperationGateHeld(
                    operation: .terminate,
                    commands: ["process kill"],
                    timeout: commandTimeout,
                    responseProjection: .none,
                    in: current
                )
                let settled = try await settleTermination(
                    termination,
                    in: current,
                    operationGateAlreadyHeld: true
                )
                guard Self.isExactLaunchedRecoveryTerminal(
                    settled.reducerState,
                    authority: authority
                ) else {
                    return await retireAndBlock(
                        reason: reason,
                        authority: authority,
                        state: settled.reducerState,
                        in: current
                    )
                }
                return await finishResolvedRecovery(
                    state: settled.reducerState,
                    reason: reason,
                    in: current
                )
            } catch {
                return await retireAndBlock(
                    reason: reason,
                    authority: authority,
                    state: await current.coordinator.reducerState,
                    in: current
                )
            }

        case .detachAttached(let authority):
            guard let attachedSession = current.exactAttachedSessionEvidence,
                  let registry = sessionLeaseAuthority.registry,
                  attachedSession.permit.authority == authority,
                  attachedSession.permit.adapterGeneration == current.adapterGeneration,
                  attachedSession.hasValidBinding() else {
                // Production exact attach has not yet installed this retained proof. An attached
                // authority without it can retire and reobserve, but cannot author detach or kill.
                return await retireAndBlock(
                    reason: reason,
                    authority: authority,
                    state: state,
                    in: current
                )
            }
            do {
                let outcome = try await current.coordinator.performExactDetachTransaction(
                    PersistentLLDBExactDetachTransactionInput(attachedSession: attachedSession)
                )
                switch outcome {
                case .detached(let detached):
                    guard Self.isExactAttachedRecoveryTerminal(
                        detached.reducerState,
                        authority: authority
                    ) else {
                        return await retireAndBlock(
                            reason: reason,
                            authority: authority,
                            state: detached.reducerState,
                            in: current
                        )
                    }
                    await current.preparer.discardOutstandingResponses()
                    let retirement = await current.adapter
                        .retireExactAttachedAdapterWithoutDebuggerCommand(boundTo: attachedSession)
                    guard case .proven(let adapterProof) = retirement else {
                        try? await registry.pinExactAttachedTerminalDispositionUnknown(
                            detach: detached
                        )
                        return recordUnresolvedRecovery(
                            reason: reason,
                            authority: authority,
                            reobservation: nil,
                            state: detached.reducerState,
                            in: current
                        )
                    }
                    try await registry.completeExactAttachedTerminalRelease(
                        detach: detached,
                        adapterRetirement: adapterProof
                    )
                    clearSessionIfCurrent(current)
                    return RecoveryOutcome(
                        snapshot: DebuggerTransportSnapshotProjector.project(
                            detached.reducerState,
                            executableName: current.executableName
                        ),
                        isResolved: true
                    )

                case .targetExited(let externalExit, let terminalState):
                    // The exact target has already exited. From this point forward cleanup is
                    // intentionally command-free: no status poll, detach, kill, quit, or retry may
                    // be written through this adapter generation.
                    let evidenceIsValid = externalExit.attachedSession == attachedSession
                        && externalExit.hasValidBinding()
                        && externalExit.adapterInstanceBindingDigest ==
                            attachedSession.adapterInstanceBinding.digest
                        && externalExit.requestID.epoch == terminalState.epoch
                        && externalExit.requestID.sequence ==
                            terminalState.lastAdmittedRequestSequence
                        && externalExit.terminalLifecycleRevision ==
                            terminalState.lifecycleRevision
                        && externalExit.processID == authority.processID
                        && Self.isExactAttachedExternalExitTerminal(
                            terminalState,
                            authority: authority
                        )
                    let settlement = await Self.settleExactAttachedExternalExit(
                        evidenceIsValid: evidenceIsValid,
                        prepareForRetirement: {
                            await current.preparer.discardOutstandingResponses()
                        },
                        retireExactAdapter: {
                            let retirement = await current.adapter
                                .retireExactAttachedAdapterWithoutDebuggerCommand(
                                    boundTo: attachedSession
                                )
                            guard case .proven(let adapterProof) = retirement else { return nil }
                            return adapterProof
                        },
                        completeRelease: { adapterProof in
                            try await registry.completeExactAttachedExternalExitRelease(
                                exit: externalExit,
                                adapterRetirement: adapterProof
                            )
                        },
                        pinDisposition: {
                            try? await registry
                                .pinExactAttachedDispositionUnknown(attachedSession)
                        }
                    )
                    switch settlement {
                    case .unresolved:
                        // Absence uncertainty is terminal for this controller generation. The
                        // registry preserves the exact attached evidence and both ownership indexes.
                        return recordUnresolvedRecovery(
                            reason: reason,
                            authority: authority,
                            reobservation: nil,
                            state: terminalState,
                            in: current
                        )
                    case .released:
                        clearSessionIfCurrent(current)
                        return RecoveryOutcome(
                            snapshot: DebuggerTransportSnapshotProjector.project(
                                terminalState,
                                executableName: current.executableName
                            ),
                            isResolved: true
                        )
                    }
                }
            } catch {
                try? await registry.pinExactAttachedDispositionUnknown(attachedSession)
                return await retireAndBlock(
                    reason: reason,
                    authority: authority,
                    state: await current.coordinator.reducerState,
                    in: current
                )
            }

        case .retireOwnedTransportAndReobserve(let authority):
            return await retireAndBlock(
                reason: reason,
                authority: authority,
                state: state,
                in: current
            )

        case .retireIdleTransport:
            return await finishResolvedRecovery(state: state, reason: reason, in: current)
        }
    }

    private func finishResolvedRecovery(
        state: DebuggerReducerState,
        reason: DebuggerRecoveryReason,
        in current: Session
    ) async -> RecoveryOutcome {
        guard await retireAdapterWithoutDebuggerCommand(in: current) else {
            return recordUnresolvedRecovery(
                reason: reason,
                authority: nil,
                reobservation: nil,
                state: state,
                in: current
            )
        }
        clearSessionIfCurrent(current)
        return RecoveryOutcome(
            snapshot: DebuggerTransportSnapshotProjector.project(
                state,
                executableName: current.executableName
            ),
            isResolved: true
        )
    }

    private func retireAndBlock(
        reason: DebuggerRecoveryReason,
        authority: DebuggerSessionTargetAuthority?,
        state: DebuggerReducerState,
        in current: Session
    ) async -> RecoveryOutcome {
        let adapterRetired = await retireAdapterWithoutDebuggerCommand(in: current)
        let reobservation = await Self.reobserveAfterRetirementKillingSurvivingLaunchedDebuggee(
            authority: authority,
            reobserve: { [weak self] in await self?.reobserveAfterCommittedRecovery(authority) },
            killLaunchedDebuggee: launchedDebuggeeKiller
        )
        // A launched target that is provably gone after proven command-free LLDB retirement has
        // an exact terminal disposition: nothing MacScope launched survives. Settle like a
        // resolved recovery so Launch Target is admitted again (same principle as an unaccepted
        // launch). Attached targets and any uncertain observation still block.
        if adapterRetired,
           Self.isLaunchedTargetProvablyGone(authority: authority, reobservation: reobservation) {
            clearSessionIfCurrent(current)
            return RecoveryOutcome(
                snapshot: DebuggerTransportSnapshotProjector.project(
                    await current.coordinator.reducerState,
                    executableName: current.executableName
                ),
                isResolved: true
            )
        }
        return recordUnresolvedRecovery(
            reason: reason,
            authority: authority,
            reobservation: reobservation,
            state: state,
            in: current
        )
    }

    typealias LaunchedDebuggeeKiller = @Sendable (DebuggerLocalProcessIdentity) async -> Void

    /// Exact absence for a launched target only: the PID no longer names any process (ESRCH),
    /// so the recorded launched instance cannot survive. Identity drift, metadata denial,
    /// attached origin and missing evidence are never treated as absence.
    nonisolated static func isLaunchedTargetProvablyGone(
        authority: DebuggerSessionTargetAuthority?,
        reobservation: DebuggerLocalProcessResolution<DebuggerLocalProcessIdentity>?
    ) -> Bool {
        guard let authority,
              case .launched(let launch) = authority.origin,
              authority.processID == launch.processID else {
            return false
        }
        switch reobservation {
        case .ineligible(.disappeared)?, .unknown(.disappeared)?:
            return true
        default:
            return false
        }
    }

    /// Last-resort cleanup after command-free retirement. LLDB normally kills the inferior it
    /// launched when its stdin closes; if the exact launched identity this session recorded is
    /// still observed alive after retirement, kill that one process so it is not left stopped and
    /// orphaned. Attached targets, unaccepted launches and any identity drift are never signalled.
    nonisolated static func reobserveAfterRetirementKillingSurvivingLaunchedDebuggee(
        authority: DebuggerSessionTargetAuthority?,
        reobserve: @escaping @Sendable () async
            -> DebuggerLocalProcessResolution<DebuggerLocalProcessIdentity>?,
        killLaunchedDebuggee: @escaping LaunchedDebuggeeKiller
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessIdentity>? {
        let reobservation = await reobserve()
        guard let authority,
              case .launched(let launch) = authority.origin,
              authority.processID == launch.processID,
              case .resolved(let survivor)? = reobservation,
              survivor == launch.identity,
              survivor.identityDigest == launch.identityDigest else {
            return reobservation
        }
        await killLaunchedDebuggee(launch.identity)
        return await reobserve()
    }

    nonisolated static func killLaunchedDebuggee(_ identity: DebuggerLocalProcessIdentity) async {
        let processID = identity.processID
        guard processID > 1, processID != getpid() else { return }
        _ = kill(processID, SIGKILL)
        // Give launchd a moment to reap the reparented inferior before identity reobservation.
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func retireAdapterWithoutDebuggerCommand(in current: Session) async -> Bool {
        await current.preparer.discardOutstandingResponses()
        let receipt = await current.adapter.retireRetainedAdapterWithoutDebuggerCommand()
        return Self.isProvenCommandFreeAdapterRetirement(receipt)
    }

    nonisolated static func isProvenCommandFreeAdapterRetirement(
        _ receipt: PersistentLLDBCLIShutdownReceipt
    ) -> Bool {
        !receipt.requestedGracefulQuit && receipt.didExit && receipt.didReap
    }

    private func reobserveAfterCommittedRecovery(
        _ authority: DebuggerSessionTargetAuthority?
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessIdentity>? {
        guard let authority else { return nil }
        let expected = Self.identity(for: authority)
        let reobserver = processIdentityReobserver
        let proofTask = Task.detached {
            await reobserver.reobserveIdentity(expected)
        }
        return await withTaskCancellationHandler {
            await proofTask.value
        } onCancel: {
            // Adapter retirement or exact detach is already committed. Caller cancellation cannot
            // truncate the mandatory two-pass identity observation or authorize another action.
        }
    }

    private func recordUnresolvedRecovery(
        reason: DebuggerRecoveryReason,
        authority: DebuggerSessionTargetAuthority?,
        reobservation: DebuggerLocalProcessResolution<DebuggerLocalProcessIdentity>?,
        state: DebuggerReducerState,
        in current: Session
    ) -> RecoveryOutcome {
        if unresolvedRecoveryBlocker == nil {
            unresolvedRecoveryBlocker = UnresolvedRecoveryBlocker(
                reason: reason,
                authority: authority,
                reobservation: reobservation
            )
        }
        clearSessionIfCurrent(current)
        return RecoveryOutcome(
            snapshot: DebuggerTransportSnapshotProjector.project(
                state,
                executableName: current.executableName
            ),
            isResolved: false
        )
    }

    private func clearSessionIfCurrent(_ current: Session) {
        guard session?.coordinator === current.coordinator else { return }
        pendingRunToCursorBreakpoint = nil
        session = nil
    }

    private nonisolated static func identity(
        for authority: DebuggerSessionTargetAuthority
    ) -> DebuggerLocalProcessIdentity {
        switch authority.origin {
        case .launched(let launch): launch.identity
        case .attached(let identity): identity
        }
    }

    /// The helper may prove that no breakpoint apply occurred while simultaneously proving that
    /// process authority is no longer trustworthy. Invalidate first, then let the one centralized
    /// policy boundary choose command-free retirement and reobservation from reducer-owned state.
    private func invalidateLogicalBreakpointSessionAfterAuthorityLossAssumingOperationGateHeld(
        in current: Session
    ) async {
        precondition(operationGateIsLocked)
        _ = try? await current.coordinator.invalidateAfterUnrecoverablePartialMutation(
            operation: .reconcileLogicalBreakpoints
        )
        _ = await recoverSessionAssumingOperationGateHeld(
            for: .callbackOrHelperAuthorityLoss,
            in: current
        )
    }

    private func terminateAfterPartialMutationFailureAssumingOperationGateHeld(
        operation: DebuggerOperation,
        in current: Session
    ) async {
        precondition(operationGateIsLocked)
        _ = await recoverSessionAssumingOperationGateHeld(
            for: .partialMutation(operation: operation),
            in: current
        )
    }

    private func requireExactAttachRuntimeAuthority() throws
        -> ExactAttachRuntimeAuthority
    {
        precondition(operationGateIsLocked)
        guard runtimeAuthorityProjectionForTesting.isObservationPolicyAuthorityReady,
              case .shared(let registry, let ownerID) = sessionLeaseAuthority,
              let factory = targetlessTransportFactory,
              let policyProvider = observationPolicyProvider,
              let registryAuthority = policyProvider.registryAuthority,
              let interlockIdentity = ownedInfrastructureInterlockIdentity,
              registryAuthority.hostIdentity.isCurrentHostProcess,
              registryAuthority.sessionLeaseRegistryID == ObjectIdentifier(registry),
              registryAuthority.attachWriteInterlockIdentity == interlockIdentity,
              registry.attachWriteInterlock.identity == interlockIdentity,
              factory.attachWriteInterlockIdentityForTesting == interlockIdentity,
              factory.localProcessEvidenceProviderIsAvailableForTesting else {
            throw DebuggerClientError.backendUnavailable(
                "Exact attach runtime authority is incomplete, crossed, or bound to another host process."
            )
        }
        return ExactAttachRuntimeAuthority(
            registry: registry,
            ownerID: ownerID,
            factory: factory,
            policyProvider: policyProvider,
            interlockIdentity: interlockIdentity
        )
    }

    private func makeExactAttachedSession(
        transport: PersistentLLDBTargetlessTransport,
        request: DebuggerLocalAttachRequest,
        result: PersistentLLDBExactAttachTransactionResult
    ) -> Session {
        let executableName = URL(
            fileURLWithPath: request.selectedIdentity.canonicalExecutablePath
        ).lastPathComponent
        return Session(
            adapter: transport.adapter,
            coordinator: transport.coordinator,
            preparer: transport.preparer,
            runtimeModuleCollector: DebuggerRuntimeModuleInventoryCollector(),
            runtimeModuleToken: Data(SHA256.hash(
                data: Data(transport.epoch.rawValue.uuidString.utf8)
            )),
            adapterGeneration: transport.adapterGeneration,
            logicalBreakpointOwnershipTagDigest: Self.logicalBreakpointOwnershipTagDigest(
                epoch: transport.epoch,
                adapterGeneration: transport.adapterGeneration
            ),
            executableName: executableName,
            exactAttachedSessionEvidence: result.attachedSession
        )
    }

    /// Both cleanup lanes are started in detached tasks before either is awaited. A failure in one
    /// lane therefore cannot suppress the other, and caller cancellation cannot truncate exact
    /// lease removal or command-free helper retirement.
    private func cleanupExactAttachBeforePermit(
        reservation: DebuggerSessionLeaseReservation,
        registry: DebuggerSessionLeaseRegistry,
        adapter: PersistentLLDBCLIAdapter?
    ) async -> ExactAttachPrePermitCleanupOutcome {
        let leaseCleanup = Task.detached(priority: .userInitiated) {
            do {
                try await registry.cancelBeforeTransportWrite(reservation)
                return true
            } catch {
                return false
            }
        }
        let adapterCleanup = Task.detached(priority: .userInitiated) {
            guard let adapter else { return true }
            let receipt = await adapter.retireRetainedAdapterWithoutDebuggerCommand()
            return Self.isProvenCommandFreeAdapterRetirement(receipt)
        }
        let leaseWasRemoved = await leaseCleanup.value
        let adapterWasProvenRetired = await adapterCleanup.value
        return ExactAttachPrePermitCleanupOutcome(
            leaseWasRemoved: leaseWasRemoved,
            adapterWasProvenRetired: adapterWasProvenRetired
        )
    }

    private func applyExactAttachPrePermitCleanupBlockers(
        _ cleanup: ExactAttachPrePermitCleanupOutcome,
        reservation: DebuggerSessionLeaseReservation,
        adapter: PersistentLLDBCLIAdapter?
    ) {
        if !cleanup.leaseWasRemoved, unresolvedRecoveryBlocker == nil {
            unresolvedRecoveryBlocker = UnresolvedRecoveryBlocker(
                reason: .adapterInterruption,
                authority: reservation.authority,
                reobservation: nil
            )
        }
        if !cleanup.adapterWasProvenRetired,
           unresolvedPreDispatchAdapterBlocker == nil,
           let adapter {
            unresolvedPreDispatchAdapterBlocker = UnresolvedPreDispatchAdapterBlocker(
                adapter: adapter
            )
        }
    }

    private func settleExactAttachTransactionFailure(
        _ failure: PersistentLLDBExactAttachTransactionFailure,
        reservation: DebuggerSessionLeaseReservation,
        registry: DebuggerSessionLeaseRegistry,
        adapter: PersistentLLDBCLIAdapter?
    ) async {
        let registrySettlement = Task.detached(priority: .userInitiated) {
            do {
                try await registry.resolveExactAttachFailure(failure)
                return true
            } catch {
                return false
            }
        }
        let registryWasSettled = await registrySettlement.value

        // Resolution runs first so a definitely-prewrite failure can atomically remove its lease,
        // while a possible write pins that same lease before helper retirement begins. Retirement
        // is nevertheless unconditional and command-free even if registry settlement failed.
        let adapterRetirement = Task.detached(priority: .userInitiated) {
            guard let adapter else { return true }
            let receipt = await adapter.retireRetainedAdapterWithoutDebuggerCommand()
            return Self.isProvenCommandFreeAdapterRetirement(receipt)
        }
        let adapterWasProvenRetired = await adapterRetirement.value

        if failure.finalCommandDisposition == .mayHaveWrittenOrAcceptedAuthority
            || !registryWasSettled {
            if unresolvedRecoveryBlocker == nil {
                unresolvedRecoveryBlocker = UnresolvedRecoveryBlocker(
                    reason: .adapterInterruption,
                    authority: reservation.authority,
                    reobservation: nil
                )
            }
        }
        if !adapterWasProvenRetired,
           unresolvedPreDispatchAdapterBlocker == nil,
           let adapter {
            unresolvedPreDispatchAdapterBlocker = UnresolvedPreDispatchAdapterBlocker(
                adapter: adapter
            )
        }
    }

    private func requireActiveController() throws {
        guard lifecycle == .active else {
            throw DebuggerClientError.backendUnavailable(Self.retiredControllerReason)
        }
    }

    private func installedSessionMatches(_ current: Session) -> Bool {
        guard let installed = session else { return false }
        return installed.coordinator === current.coordinator
            && installed.adapter === current.adapter
            && installed.adapterGeneration == current.adapterGeneration
    }

    private func requireInstalledSessionIdentity(_ current: Session) throws {
        guard installedSessionMatches(current) else {
            throw DebuggerClientError.invalidState(
                "The debugger session was retired or replaced before command admission."
            )
        }
    }

    private func requireCommandAdmissionAuthority(_ current: Session) throws {
        try requireInstalledSessionIdentity(current)
        guard lifecycle == .active || shutdownDrainOwnsOperationGate else {
            throw DebuggerClientError.backendUnavailable(Self.retiredControllerReason)
        }
    }

    private func requirePublicationAuthority(
        for current: Session,
        state: DebuggerReducerState
    ) throws {
        try requireActiveController()
        if Self.isTerminalNoLive(state.processPhase) {
            guard session == nil || installedSessionMatches(current) else {
                throw DebuggerClientError.invalidState(
                    "A retired debugger session cannot publish over its replacement."
                )
            }
        } else {
            try requireInstalledSessionIdentity(current)
        }
    }

    private func acquireOperationGate() async {
        if !operationGateIsLocked {
            operationGateIsLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            operationGateWaiters.append(continuation)
        }
    }

    private func requirePreDispatchAuthority(
        retiringOnFailure adapter: PersistentLLDBCLIAdapter
    ) async throws {
        do {
            try requireActiveController()
            try Task.checkCancellation()
        } catch {
            try await retirePreDispatchAdapterRequiringProof(
                adapter,
                unprovenMessage:
                    "The cancelled LLDB child could not be proven exited and reaped; restart MacScope before launching another target."
            )
            throw error
        }
    }

    private func retirePreDispatchAdapterRequiringProof(
        _ adapter: PersistentLLDBCLIAdapter,
        unprovenMessage: String
    ) async throws {
        // Retained-process exit polling is cancellable, so cleanup must run outside the failed
        // launch task. Awaiting the fresh task makes proof completion part of the launch result.
        let cleanup = Task.detached(priority: .userInitiated) {
            await adapter.retireRetainedAdapterWithoutDebuggerCommand()
        }
        let receipt = await cleanup.value
        guard Self.isProvenCommandFreeAdapterRetirement(receipt) else {
            unresolvedPreDispatchAdapterBlocker = UnresolvedPreDispatchAdapterBlocker(
                adapter: adapter
            )
            throw DebuggerClientError.backendUnavailable(unprovenMessage)
        }
    }

    private func releaseOperationGate() {
        if operationGateWaiters.isEmpty {
            operationGateIsLocked = false
            return
        }
        let next = operationGateWaiters.removeFirst()
        next.resume()
    }

    private func finish(
        _ result: PersistentLLDBSessionExecutionResult,
        in current: Session,
        forceRuntimeModuleRefresh: Bool = false,
        operationGateAlreadyHeld: Bool = false
    ) async throws -> DebuggerSessionSnapshot {
        if operationGateAlreadyHeld {
            precondition(operationGateIsLocked)
        }
        try requirePublicationAuthority(for: current, state: result.reducerState)
        var accepted = result
        if case .stopped = accepted.reducerState.processPhase,
           pendingRunToCursorBreakpoint?.epoch == accepted.reducerState.epoch {
            do {
                accepted = try await cleanupRunToCursorBreakpointIfStopped(
                    accepted,
                    in: current,
                    operationGateAlreadyHeld: operationGateAlreadyHeld
                )
            } catch {
                let recovery = await terminateAfterRunToCursorFailure(
                    in: current,
                    operationGateAlreadyHeld: operationGateAlreadyHeld
                )
                try requirePublicationAuthority(
                    for: current,
                    state: await current.coordinator.reducerState
                )
                return recovery.snapshot
            }
        }

        if case .stopped = accepted.reducerState.processPhase,
           accepted.reducerState.stoppedData == nil {
            do {
                if operationGateAlreadyHeld {
                    accepted = try await performAssumingOperationGateHeld(
                        operation: .refreshSnapshot,
                        commands: Self.stoppedRefreshCommands,
                        timeout: commandTimeout,
                        responseProjection: .stoppedData,
                        in: current
                    )
                } else {
                    accepted = try await perform(
                        .refreshSnapshot,
                        commands: Self.stoppedRefreshCommands,
                        responseProjection: .stoppedData,
                        in: current
                    )
                }
            } catch {
                // Lifecycle remains reducer-authoritative even when optional presentation detail
                // cannot be recovered. The reducer retains the bounded semantic diagnostic.
                let authoritativeState = try Self
                    .authoritativeStateAfterAutomaticStoppedRefreshFailure(
                        await current.coordinator.reducerState
                    )
                accepted = PersistentLLDBSessionExecutionResult(
                    requestID: accepted.requestID,
                    reducerState: authoritativeState
                )
            }
        }

        if case .stopped = accepted.reducerState.processPhase,
           forceRuntimeModuleRefresh || Self.shouldRefreshRuntimeModules(accepted.reducerState) {
            do {
                accepted = try await refreshRuntimeModules(
                    in: current,
                    operationGateAlreadyHeld: operationGateAlreadyHeld
                )
            } catch {
                let authoritativeState = await current.coordinator.reducerState
                guard !authoritativeState.isInvalidated else {
                    await shutdownInvalidatedSession(
                        in: current,
                        operationGateAlreadyHeld: operationGateAlreadyHeld
                    )
                    throw map(error, operation: .refreshRuntimeModules)
                }
                // A fully correlated semantic collection failure is nonfatal to the stopped
                // process. Its newer unavailable authority is the honest compatibility result.
                accepted = PersistentLLDBSessionExecutionResult(
                    requestID: accepted.requestID,
                    reducerState: authoritativeState
                )
            }
        }

        if Self.isTerminalNoLive(accepted.reducerState.processPhase) {
            let recovery: RecoveryOutcome
            if operationGateAlreadyHeld {
                recovery = await recoverSessionAssumingOperationGateHeld(
                    for: .adapterInterruption,
                    in: current
                )
            } else {
                recovery = await recoverSession(for: .adapterInterruption, in: current)
            }
            try requirePublicationAuthority(
                for: current,
                state: await current.coordinator.reducerState
            )
            return recovery.snapshot
        }
        try requirePublicationAuthority(for: current, state: accepted.reducerState)
        return DebuggerTransportSnapshotProjector.project(
            accepted.reducerState,
            executableName: current.executableName
        )
    }

    private func shutdownInvalidatedSession(
        in current: Session,
        operationGateAlreadyHeld: Bool = false
    ) async {
        if operationGateAlreadyHeld {
            _ = await recoverSessionAssumingOperationGateHeld(
                for: .adapterInterruption,
                in: current
            )
        } else {
            _ = await recoverSession(for: .adapterInterruption, in: current)
        }
    }

    private static func shouldRefreshRuntimeModules(_ state: DebuggerReducerState) -> Bool {
        guard case .stopped = state.processPhase else { return false }
        switch state.runtimeModuleInventoryState.authority {
        case .available(let inventory):
            return inventory.stop != state.stopCoordinate
                || inventory.processID != state.observedProcessID
        case .unavailable(.refreshFailed):
            return false
        case .unavailable:
            return true
        }
    }

    private func refreshRuntimeModules(
        in current: Session,
        operationGateAlreadyHeld: Bool = false
    ) async throws -> PersistentLLDBSessionExecutionResult {
        if !operationGateAlreadyHeld {
            await acquireOperationGate()
        } else {
            precondition(operationGateIsLocked)
        }
        do {
            try requireActiveController()
            try requireInstalledSessionIdentity(current)
            try Task.checkCancellation()
            let state = await current.coordinator.reducerState
            guard case .stopped = state.processPhase,
                  let stop = state.stopCoordinate else {
                throw DebuggerClientError.invalidState(
                    "Runtime-module refresh requires a paused live debug process."
                )
            }
            let result = try await current.coordinator.performRuntimeModuleRefresh(
                expectedSession: state.sessionCoordinate,
                requiredStop: stop,
                adapterGeneration: current.adapterGeneration,
                token: current.runtimeModuleToken,
                collector: current.runtimeModuleCollector
            )
            if !operationGateAlreadyHeld { releaseOperationGate() }
            return result
        } catch {
            if !operationGateAlreadyHeld { releaseOperationGate() }
            throw error
        }
    }

    private func cleanupRunToCursorBreakpointIfStopped(
        _ result: PersistentLLDBSessionExecutionResult,
        in current: Session,
        operationGateAlreadyHeld: Bool = false
    ) async throws -> PersistentLLDBSessionExecutionResult {
        guard case .stopped = result.reducerState.processPhase,
              let pending = pendingRunToCursorBreakpoint,
              pending.epoch == result.reducerState.epoch else {
            if let pending = pendingRunToCursorBreakpoint,
               Self.shouldDiscardPendingRunToCursorBreakpoint(
                pendingEpoch: pending.epoch,
                resultEpoch: result.reducerState.epoch,
                resultIsTerminal: Self.isTerminalNoLive(result.reducerState.processPhase)
               ) {
                pendingRunToCursorBreakpoint = nil
            }
            return result
        }
        if !operationGateAlreadyHeld {
            await acquireOperationGate()
        } else {
            precondition(operationGateIsLocked)
        }
        defer {
            if !operationGateAlreadyHeld { releaseOperationGate() }
        }
        try requireInstalledSessionIdentity(current)
        let cleanedState = try await current.coordinator.cleanupRunToCursorBinding(
            PersistentLLDBRunToCursorCleanupInput(
                receipt: pending.receipt,
                ownerDigest: pending.ownerDigest,
                token: pending.token
            )
        )
        pendingRunToCursorBreakpoint = nil
        return PersistentLLDBSessionExecutionResult(
            requestID: result.requestID,
            reducerState: cleanedState
        )
    }

    private func settleTermination(
        _ initial: PersistentLLDBSessionExecutionResult,
        in current: Session,
        operationGateAlreadyHeld: Bool = false
    ) async throws -> PersistentLLDBSessionExecutionResult {
        var result = initial
        for _ in 0..<20 {
            if Self.isTerminalNoLive(result.reducerState.processPhase) { return result }
            try await ContinuousClock().sleep(for: .milliseconds(25))
            if operationGateAlreadyHeld {
                precondition(operationGateIsLocked)
                result = try await performAssumingOperationGateHeld(
                    operation: .pollProcessStatus,
                    commands: [],
                    timeout: pollTimeout,
                    responseProjection: .none,
                    in: current
                )
            } else {
                result = try await perform(
                    .pollProcessStatus,
                    commands: [],
                    timeout: pollTimeout,
                    in: current
                )
            }
        }
        return result
    }

    private func settlePause(
        _ initial: PersistentLLDBSessionExecutionResult,
        in current: Session
    ) async throws -> PersistentLLDBSessionExecutionResult {
        var result = initial
        for _ in 0..<40 {
            switch result.reducerState.processPhase {
            case .stopped, .detaching, .exited, .detached, .terminated, .invalidated:
                return result
            case .running:
                try await ContinuousClock().sleep(for: .milliseconds(25))
                result = try await perform(
                    .pollProcessStatus,
                    commands: [],
                    timeout: pollTimeout,
                    in: current
                )
            case .noTarget:
                return result
            }
        }
        return result
    }

    private func terminateAfterRunToCursorFailure(
        in current: Session,
        operationGateAlreadyHeld: Bool = false
    ) async -> RecoveryOutcome {
        let state = await current.coordinator.reducerState
        if let pending = pendingRunToCursorBreakpoint,
           Self.pendingRunToCursorAuthorityMatches(
            pendingEpoch: pending.epoch,
            sessionEpoch: state.epoch
           ) {
            pendingRunToCursorBreakpoint = nil
        }
        if operationGateAlreadyHeld {
            precondition(operationGateIsLocked)
            return await recoverSessionAssumingOperationGateHeld(
                for: .runToCursorCleanup,
                in: current
            )
        } else {
            return await recoverSession(for: .runToCursorCleanup, in: current)
        }
    }

    private func awaitActivePoll() async throws {
        guard let activePoll else { return }
        do {
            _ = try await activePoll.value
        } catch {
            self.activePoll = nil
            throw map(error, operation: .pollProcessStatus)
        }
        self.activePoll = nil
    }

    private func requireNoLiveOrUnknownTargetBeforeLaunch() async throws {
        precondition(operationGateIsLocked)
        try requireActiveController()
        if unresolvedPreDispatchAdapterBlocker != nil {
            throw DebuggerClientError.backendUnavailable(
                "A prior LLDB child lacks proven command-free exit and reap; restart MacScope before launching another target."
            )
        }
        if let blocker = unresolvedRecoveryBlocker {
            let target = blocker.authority.map { " PID \($0.processID)" } ?? ""
            throw DebuggerClientError.backendUnavailable(
                "The prior debugger recovery for \(blocker.reason.rawValue) left\(target) "
                    + "without exact terminal disposition proof."
            )
        }
        guard let current = session else { return }
        let state = await current.coordinator.reducerState
        switch state.processPhase {
        case .noTarget, .exited, .detached, .terminated:
            return
        case .running, .stopped:
            throw DebuggerClientError.invalidState(
                "Terminate the current live debug process before launching another target."
            )
        case .detaching, .invalidated:
            throw DebuggerClientError.backendUnavailable(
                "The prior LLDB session lost exact target disposition; restart MacScope before launching another target."
            )
        }
    }

    private func shutdownIdleSessionAssumingOperationGateHeld() async throws {
        precondition(operationGateIsLocked)
        try requireActiveController()
        guard let old = session else { return }
        let outcome = await recoverSessionAssumingOperationGateHeld(
            for: .sessionReplacement,
            in: old
        )
        guard outcome.isResolved else {
            throw DebuggerClientError.backendUnavailable(
                "The prior debugger target disposition remains unresolved."
            )
        }
    }

    private static func isTerminalNoLive(_ phase: DebuggerReducerProcessPhase) -> Bool {
        switch phase {
        case .exited, .detached, .terminated:
            return true
        case .noTarget, .running, .stopped, .detaching, .invalidated:
            return false
        }
    }

    private func requireSession(for operation: DebuggerOperation) throws -> Session {
        try requireActiveController()
        guard let session else {
            throw DebuggerClientError.invalidState(
                "\(operation.displayLabel) requires an established persistent LLDB session."
            )
        }
        return session
    }

    private func requireStoppedSession(for operation: DebuggerOperation) async throws -> Session {
        try requireActiveController()
        guard let session else {
            throw DebuggerClientError.invalidState(
                "\(operation.displayLabel) requires an established persistent LLDB session."
            )
        }
        let state = await session.coordinator.reducerState
        try requireActiveController()
        try requireInstalledSessionIdentity(session)
        guard case .stopped = state.processPhase, state.stopCoordinate != nil else {
            throw DebuggerClientError.invalidState(
                "\(operation.displayLabel) requires a paused live debug process."
            )
        }
        return session
    }

    private static func transportBreakpoint(
        _ breakpoint: DebuggerBreakpoint
    ) -> DebuggerTransportBreakpoint {
        DebuggerTransportBreakpoint(
            address: breakpoint.address,
            isEnabled: breakpoint.isEnabled,
            condition: breakpoint.condition,
            hitCount: breakpoint.hitCount,
            ignoreCount: breakpoint.ignoreCount,
            backendIdentifier: nil
        )
    }

    private static func legacyBreakpoint(
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

    private func unsupported(
        _ operation: DebuggerOperation,
        detail: String
    ) -> DebuggerClientError {
        .unsupportedOperation("\(operation.displayLabel) is unavailable: \(detail).")
    }

    private func map(_ error: Error, operation: DebuggerOperation) -> DebuggerClientError {
        if let error = error as? DebuggerClientError { return error }
        if let error = error as? PersistentLLDBSessionCoordinatorFailure {
            // `detail` names the adapter invalidation cause (timeout and its deadline, EOF,
            // framing, correlation) instead of a bare `adapterInvalidated` (§4.88).
            return .backendFailure(
                "\(operation.displayLabel) failed in the correlated LLDB session (\(error.detail))."
            )
        }
        if let error = error as? PersistentLLDBLogicalBreakpointReconciliationFailure {
            return .backendFailure(
                "\(operation.displayLabel) failed in the correlated LLDB session (\(error.code.rawValue))."
            )
        }
        if let error = error as? PersistentLLDBLogicalBreakpointCallbackDrainFailure {
            return .backendFailure(
                "\(operation.displayLabel) failed while draining correlated logical-breakpoint callbacks (\(error.code.rawValue)); bounded fail-closed target recovery was attempted."
            )
        }
        return .backendFailure("\(operation.displayLabel) failed: \(error.localizedDescription)")
    }
}
