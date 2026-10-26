import CryptoKit
import Darwin
import Foundation

/// Opt-in installed-app smoke for the Phase 2 R2 human shell surface.
///
/// This runner is admitted inside the MacScope app process before SwiftUI scenes are created,
/// then runs alongside the smoke-only renderer scene. App-private XPC services are resolved
/// relative to the containing app bundle, so an external helper cannot prove the same
/// ShellBroker and renderer path the installed app uses.
enum Phase2InstalledShellSmokeRunner {
    static let reportPathEnvironmentKey = "MACSCOPE_PHASE2_INSTALLED_SHELL_SMOKE_REPORT"
    static let markerEnvironmentKey = "MACSCOPE_PHASE2_INSTALLED_SHELL_SMOKE_MARKER"
    static let timeoutEnvironmentKey = "MACSCOPE_PHASE2_INSTALLED_SHELL_SMOKE_TIMEOUT_SECONDS"
    static let modeEnvironmentKey = "MACSCOPE_PHASE2_INSTALLED_SHELL_SMOKE_MODE"
    static let rendezvousPathEnvironmentKey = "MACSCOPE_PHASE2_INSTALLED_SHELL_SMOKE_RENDEZVOUS"
    static let stopSentinelPathEnvironmentKey = "MACSCOPE_PHASE2_INSTALLED_SHELL_SMOKE_STOP_SENTINEL"
    static let rendererModeEnvironmentKey = "MACSCOPE_PHASE2_INSTALLED_SHELL_SMOKE_RENDERER_MODE"

    static let schemaVersion = 5
    private static let defaultTimeoutSeconds = 5.0
    private static let maximumReportBytes = 32 * 1024
    private static let maximumBuildProvenanceBytes = 1024 * 1024
    private static let buildProvenanceResourceName = "MacScopeBuildProvenance.json"

    enum RunStatus: String, Encodable, Equatable, Sendable {
        case passed
        case failed
    }

    enum RendererMode: String, Equatable, Sendable {
        case defaultFullGhosttySurface
        case forcedLegacyGridRecoveryOverride

        fileprivate var expectedBackend: RendererBackend {
            switch self {
            case .defaultFullGhosttySurface: .ghosttyFullSurface
            case .forcedLegacyGridRecoveryOverride: .macScopeGhosttyVTGrid
            }
        }

        fileprivate var expectedFallbackReason: RendererFallbackReason? {
            switch self {
            case .defaultFullGhosttySurface: nil
            case .forcedLegacyGridRecoveryOverride: .recoveryOverride
            }
        }
    }

    /// Closed schema vocabulary only. Runtime selection remains exclusively owned by the
    /// injected renderer/view authority.
    enum RendererBackend: String, Equatable, Sendable {
        case ghosttyFullSurface
        case macScopeGhosttyVTGrid
    }

    /// The only fallback that can satisfy this smoke. All operational fallback states must make
    /// the provider throw or return an observation that this runner rejects.
    enum RendererFallbackReason: String, Equatable, Sendable {
        case recoveryOverride
    }

    /// One-use, content-free coordinate supplied to the presentation authority. `generation`
    /// prevents an observation retained from an earlier instantiation from satisfying this run.
    struct RendererEvidenceRequest: Equatable, Sendable {
        let requestedMode: RendererMode
        let generation: UUID
        let shellSessionID: UUID
        let shellRequestID: UUID
        let shellProcessIdentifier: Int32
    }

    /// Content-free presentation observation returned by the separately owned renderer/view
    /// authority. The provider must return only after the exact requested surface is instantiated
    /// and presented. It must derive backend/fallback from the existing
    /// `Phase2TerminalRendererSelection` authority and presentation flags from the mounted view,
    /// never by echoing the request. Terminal bytes, cells, and transcript text are deliberately
    /// absent.
    struct RendererRuntimeEvidence: Equatable, Sendable {
        let requestedMode: RendererMode
        let generation: UUID
        let selectedBackend: RendererBackend
        let fallbackReason: RendererFallbackReason?
        let rendererPresented: Bool
        let transcriptOnlyFallbackPresented: Bool
        let shellSessionID: UUID
        let shellRequestID: UUID
        let shellProcessIdentifier: Int32
    }

    /// Content-free receipt from the separately owned smoke presentation seam. The renderer
    /// binding is created from the mounted view's exact running shell lifecycle; it is the only
    /// process-coordinate authority consumed by the evidence adapter.
    struct RendererPresentationLease: Equatable, Sendable {
        let requestGeneration: UUID
        let rendererBinding: MacScopeGhosttySurfaceDiagnostics.RendererBinding
        let rendererEvidenceSequenceBaseline: UInt64
    }

    typealias RendererPresentationProvider = @MainActor @Sendable (
        _ request: RendererEvidenceRequest,
        _ snapshot: Phase2HumanPTYSessionSnapshot
    ) async throws -> RendererPresentationLease

    typealias RendererEvidenceProvider = @MainActor @Sendable (
        _ request: RendererEvidenceRequest,
        _ presentation: RendererPresentationLease
    ) async throws -> RendererRuntimeEvidence

    struct RendererIntegration: Sendable {
        let presentationProvider: RendererPresentationProvider
        let evidenceProvider: RendererEvidenceProvider
    }

    struct RendererEvidence: Encodable, Equatable, Sendable {
        let requestedMode: RendererMode
        let selectedBackend: RendererBackend
        let fallbackReason: RendererFallbackReason?
        let rendererPresented: Bool
        let transcriptOnlyFallbackPresented: Bool
        let shellSessionID: UUID
        let shellRequestID: UUID
        let shellProcessIdentifier: Int32

        private enum CodingKeys: String, CodingKey {
            case requestedMode
            case selectedBackend
            case fallbackReason
            case rendererPresented
            case transcriptOnlyFallbackPresented
            case shellSessionID
            case shellRequestID
            case shellProcessIdentifier
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(requestedMode.rawValue, forKey: .requestedMode)
            try container.encode(selectedBackend.rawValue, forKey: .selectedBackend)
            if let fallbackReason {
                try container.encode(fallbackReason.rawValue, forKey: .fallbackReason)
            } else {
                try container.encodeNil(forKey: .fallbackReason)
            }
            try container.encode(rendererPresented, forKey: .rendererPresented)
            try container.encode(
                transcriptOnlyFallbackPresented,
                forKey: .transcriptOnlyFallbackPresented
            )
            try container.encode(shellSessionID.uuidString.lowercased(), forKey: .shellSessionID)
            try container.encode(shellRequestID.uuidString.lowercased(), forKey: .shellRequestID)
            try container.encode(shellProcessIdentifier, forKey: .shellProcessIdentifier)
        }
    }

    struct BuildIdentity: Equatable, Sendable {
        let sourceCommit: String
        let sourceTree: String
        let buildProvenanceSHA256: String
    }

    struct Report: Encodable, Equatable, Sendable {
        let schemaVersion: Int
        let status: RunStatus
        let generatedAtUnixMilliseconds: Int64
        let appExecutablePath: String
        let appExecutableSHA256: String
        let sourceCommit: String?
        let sourceTree: String?
        let buildProvenanceSHA256: String?
        let rendererEvidence: RendererEvidence?
        let shellBrokerServiceIdentifier: String
        let shellBrokerWireProtocol: String
        let supportedCommands: [String]
        let launchedProcessIdentifier: Int32?
        let observedReply: String?
        let acceptedTranscriptEventCount: Int
        let reconnectAcceptedTranscriptEventCount: Int
        let cleanupObservedProcessAbsent: Bool
        let mode: String?
        let brokerIncarnationID: UUID?
        let processStartTimeUnixNanoseconds: UInt64?
        let executablePath: String?
        let processGroupIdentifier: Int32?
        let transcriptCursor: UInt64?
        let bufferedMarker: String?
        let bufferedMarkerAcceptedCount: Int?
        let transcriptCursorAdvanced: Bool?
        let capabilityRemoved: Bool?
        let rendezvousRemoved: Bool?
        let error: String?

        var passed: Bool {
            status == .passed
        }
    }

    private struct SmokeError: Error, CustomStringConvertible, Sendable {
        let description: String
    }

    private enum Mode: String {
        case prepare = "PREPARE"
        case resume = "RESUME"
        case cleanup = "CLEANUP"
    }

    /// Public recovery evidence only. The bearer secret is held exclusively in Keychain.
    private struct Rendezvous: Codable {
        static let schemaVersion = 1

        let schemaVersion: Int
        let identity: Phase2DurableShellBrokerIdentity
        let transcriptCursor: UInt64
        let marker: String
    }

    private struct EmbeddedBuildProvenance: Decodable {
        let schemaVersion: Int
        let qualificationEligible: Bool
        let configuration: String
        let sourceCommit: String
        let sourceTree: String
        let repositoryClean: Bool
        let ghosttySurfaceCompilationCondition: String

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case qualificationEligible = "qualification_eligible"
            case configuration
            case sourceCommit = "git_head_commit"
            case sourceTree = "git_head_tree"
            case repositoryClean = "repository_clean"
            case ghosttySurfaceCompilationCondition = "ghostty_surface_compilation_condition"
        }
    }

    static func runIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        rendererPresentationProvider: RendererPresentationProvider? = nil,
        rendererEvidenceProvider: RendererEvidenceProvider? = nil
    ) -> Bool {
        guard startIfRequested(
            environment: environment,
            rendererPresentationProvider: rendererPresentationProvider,
            rendererEvidenceProvider: rendererEvidenceProvider
        ) else { return false }
        dispatchMain()
    }

    /// Starts the installed smoke without taking over the process run loop. The app entry point
    /// uses this route only for the installed-renderer smoke so SwiftUI can create and mount the
    /// real presentation surface while the existing ShellBroker workflow runs concurrently.
    /// Headless callers retain `runIfRequested`, whose dispatch-only behavior is unchanged.
    static func startIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        rendererPresentationProvider: RendererPresentationProvider? = nil,
        rendererEvidenceProvider: RendererEvidenceProvider? = nil
    ) -> Bool {
        guard let reportPath = environment[reportPathEnvironmentKey],
              !reportPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }

        Task {
            let reportURL = URL(fileURLWithPath: reportPath)
            let marker = environment[markerEnvironmentKey] ?? "macscope-installed-shell-smoke"
            let timeoutSeconds = parseTimeout(environment[timeoutEnvironmentKey])
            var admittedBuildIdentity: BuildIdentity?
            do {
                let requestedRendererMode = try rendererMode(environment: environment)
                let buildIdentity = try loadEmbeddedBuildIdentity()
                admittedBuildIdentity = buildIdentity
                guard let rendererPresentationProvider, let rendererEvidenceProvider else {
                    throw SmokeError(
                        description: "Installed renderer presentation integration is unavailable."
                    )
                }
                let rendererIntegration = RendererIntegration(
                    presentationProvider: rendererPresentationProvider,
                    evidenceProvider: rendererEvidenceProvider
                )
                let mode: Mode?
                if let rawMode = environment[modeEnvironmentKey] {
                    guard let parsedMode = Mode(rawValue: rawMode) else {
                        throw SmokeError(description: "Installed restart smoke mode is invalid.")
                    }
                    mode = parsedMode
                } else {
                    mode = nil
                }
                let report: Report
                if let mode {
                    guard let rendezvousPath = environment[rendezvousPathEnvironmentKey],
                          !rendezvousPath.isEmpty else {
                        throw SmokeError(description: "Installed restart smoke requires a rendezvous path.")
                    }
                    report = try await runRestart(
                        mode: mode,
                        marker: marker,
                        rendezvousURL: URL(fileURLWithPath: rendezvousPath),
                        stopSentinelURL: environment[stopSentinelPathEnvironmentKey].map(URL.init(fileURLWithPath:)),
                        timeoutSeconds: timeoutSeconds,
                        rendererMode: requestedRendererMode,
                        buildIdentity: buildIdentity,
                        rendererIntegration: rendererIntegration
                    )
                } else {
                    report = try await run(
                        marker: marker,
                        timeoutSeconds: timeoutSeconds,
                        rendererMode: requestedRendererMode,
                        buildIdentity: buildIdentity,
                        rendererIntegration: rendererIntegration
                    )
                }
                try write(report, to: reportURL)
                NSLog("MacScope installed shell smoke %@ %@ passed", marker, mode?.rawValue ?? "SINGLE")
                if mode == .prepare {
                    guard let sentinelPath = environment[stopSentinelPathEnvironmentKey] else {
                        throw SmokeError(description: "PREPARE stop sentinel path is missing.")
                    }
                    try await waitForCooperativeStop(
                        at: URL(fileURLWithPath: sentinelPath),
                        timeoutSeconds: 30
                    )
                    Darwin.exit(EXIT_SUCCESS)
                }
                Darwin.exit(report.passed ? EXIT_SUCCESS : EX_SOFTWARE)
            } catch {
                let report = failureReport(error: error, buildIdentity: admittedBuildIdentity)
                try? write(report, to: reportURL)
                Darwin.exit(EX_SOFTWARE)
            }
        }
        return true
    }

    static func run(
        marker: String,
        timeoutSeconds: Double = defaultTimeoutSeconds,
        rendererMode: RendererMode,
        buildIdentity: BuildIdentity,
        rendererIntegration: RendererIntegration
    ) async throws -> Report {
        let transport = NSXPCShellBrokerTransport()
        defer {
            Task { await transport.reset() }
        }
        let client = Phase2HumanPTYShellSessionClient(transport: transport)
        let handshake = try await withTransportDeadline(
            timeoutSeconds: timeoutSeconds,
            operationDescription: "ShellBroker handshake",
            transport: transport
        ) {
            try await transport.handshake()
        }
        let receipt = try await withTransportDeadline(
            timeoutSeconds: timeoutSeconds,
            operationDescription: "ShellBroker process receipt",
            transport: transport
        ) {
            try await transport.prepareBrokerProcessReceipt()
        }
        guard await transport.revalidateBrokerProcessReceipt(receipt) else {
            throw SmokeError(description: "ShellBroker receipt did not revalidate.")
        }

        let sessionID = UUID()
        let requestID = UUID()
        let plan = Phase2HumanPTYLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/sh",
            arguments: ["-c", "IFS= read -r line; printf 'reply:%s\\n' \"$line\"; sleep 30"],
            initialSize: .defaultInteractive,
            transcriptLimits: .productionMaximum
        )

        var snapshot = Phase2HumanPTYSessionSnapshot.initial(sessionID: sessionID)
        var launchedProcessIdentifier: Int32?
        var acceptedEvents: [Phase2HumanPTYTranscriptEvent] = []
        var cleanupObservedProcessAbsent = false
        do {
            let launchSnapshot = snapshot
            let launch = try await withTransportDeadline(
                timeoutSeconds: timeoutSeconds,
                operationDescription: "ShellBroker launch",
                transport: transport
            ) {
                try await client.launch(snapshot: launchSnapshot, plan: plan)
            }
            snapshot = launch.snapshot
            guard snapshot.sessionID == sessionID,
                  case .running(let runningRequestID, let processIdentifier) = snapshot.state,
                  runningRequestID == requestID,
                  processIdentifier > 1 else {
                throw SmokeError(
                    description: "Installed ShellBroker launch returned a mismatched process coordinate."
                )
            }
            launchedProcessIdentifier = processIdentifier

            let inputSnapshot = snapshot
            let markerBytes = Array("\(marker)\n".utf8)
            let input = try await withTransportDeadline(
                timeoutSeconds: timeoutSeconds,
                operationDescription: "ShellBroker input",
                transport: transport
            ) {
                try await client.writeInput(
                    snapshot: inputSnapshot,
                    requestID: requestID,
                    bytes: markerBytes
                )
            }
            snapshot = input.snapshot
            acceptedEvents.append(contentsOf: input.acceptedTranscriptEvents)

            let observedReply = try await pollForReply(
                client: client,
                snapshot: &snapshot,
                requestID: requestID,
                marker: marker,
                acceptedEvents: &acceptedEvents,
                timeoutSeconds: timeoutSeconds,
                transport: transport
            )
            let reconnectSnapshot = snapshot
            let reconnectID = UUID()
            let reconnect = try await withTransportDeadline(
                timeoutSeconds: timeoutSeconds,
                operationDescription: "ShellBroker reconnect",
                transport: transport
            ) {
                try await client.reconnect(
                    snapshot: reconnectSnapshot,
                    requestID: requestID,
                    reconnectID: reconnectID
                )
            }
            snapshot = reconnect.snapshot
            acceptedEvents.append(contentsOf: reconnect.acceptedTranscriptEvents)
            let reconnectAcceptedTranscriptEventCount = reconnect.acceptedTranscriptEvents.filter { event in
                if case .reconnect = event.payload {
                    return event.source == .app
                }
                return false
            }.count
            guard reconnectAcceptedTranscriptEventCount == 1 else {
                throw SmokeError(description: "Installed ShellBroker reconnect did not return exactly one app-owned reconnect event.")
            }
            guard snapshot.sessionID == sessionID,
                  case .running(let evidenceRequestID, let evidenceProcessIdentifier) = snapshot.state,
                  evidenceRequestID == requestID,
                  evidenceProcessIdentifier == processIdentifier else {
                throw SmokeError(
                    description: "Installed ShellBroker reconnect changed the process coordinate."
                )
            }

            let rendererEvidence = try await captureRendererEvidence(
                rendererMode: rendererMode,
                snapshot: snapshot,
                integration: rendererIntegration
            )

            let cleanupSnapshot = snapshot
            let cleanup = try await withTransportDeadline(
                timeoutSeconds: min(timeoutSeconds, 5),
                operationDescription: "ShellBroker cleanup",
                transport: transport
            ) {
                try await client.cleanup(
                    snapshot: cleanupSnapshot,
                    requestID: requestID,
                    reason: "installedShellSmoke"
                )
            }
            try validateCleanupObservedProcessAbsent(
                cleanup.brokerResponse?.observedProcessAbsent
            )
            cleanupObservedProcessAbsent = true

            return Report(
                schemaVersion: schemaVersion,
                status: .passed,
                generatedAtUnixMilliseconds: unixMilliseconds(),
                appExecutablePath: Bundle.main.executableURL?.path ?? "",
                appExecutableSHA256: try appExecutableSHA256(),
                sourceCommit: buildIdentity.sourceCommit,
                sourceTree: buildIdentity.sourceTree,
                buildProvenanceSHA256: buildIdentity.buildProvenanceSHA256,
                rendererEvidence: rendererEvidence,
                shellBrokerServiceIdentifier: handshake.serviceIdentifier,
                shellBrokerWireProtocol: handshake.wireProtocol,
                supportedCommands: handshake.supportedCommands,
                launchedProcessIdentifier: launchedProcessIdentifier,
                observedReply: observedReply,
                acceptedTranscriptEventCount: acceptedEvents.count,
                reconnectAcceptedTranscriptEventCount: reconnectAcceptedTranscriptEventCount,
                cleanupObservedProcessAbsent: cleanupObservedProcessAbsent,
                mode: nil,
                brokerIncarnationID: nil,
                processStartTimeUnixNanoseconds: nil,
                executablePath: nil,
                processGroupIdentifier: nil,
                transcriptCursor: nil,
                bufferedMarker: nil,
                bufferedMarkerAcceptedCount: nil,
                transcriptCursorAdvanced: nil,
                capabilityRemoved: nil,
                rendezvousRemoved: nil,
                error: nil
            )
        } catch {
            if case .running = snapshot.state {
                let cleanupSnapshot = snapshot
                _ = try? await withTransportDeadline(
                    timeoutSeconds: min(timeoutSeconds, 5),
                    operationDescription: "ShellBroker failure cleanup",
                    transport: transport
                ) {
                    try await client.cleanup(
                        snapshot: cleanupSnapshot,
                        requestID: requestID,
                        reason: "installedShellSmokeFailure"
                    )
                }
            }
            throw error
        }
    }

    private static func runRestart(
        mode: Mode,
        marker: String,
        rendezvousURL: URL,
        stopSentinelURL: URL?,
        timeoutSeconds: Double,
        rendererMode: RendererMode,
        buildIdentity: BuildIdentity,
        rendererIntegration: RendererIntegration
    ) async throws -> Report {
        switch mode {
        case .prepare:
            guard let stopSentinelURL else {
                throw SmokeError(description: "PREPARE stop sentinel path is missing.")
            }
            return try await prepareRestart(
                marker: marker,
                rendezvousURL: rendezvousURL,
                stopSentinelURL: stopSentinelURL,
                timeoutSeconds: timeoutSeconds,
                rendererMode: rendererMode,
                buildIdentity: buildIdentity,
                rendererIntegration: rendererIntegration
            )
        case .resume:
            return try await resumeRestart(
                marker: marker,
                rendezvousURL: rendezvousURL,
                timeoutSeconds: timeoutSeconds,
                rendererMode: rendererMode,
                buildIdentity: buildIdentity,
                rendererIntegration: rendererIntegration
            )
        case .cleanup:
            return try await cleanupRestart(
                marker: marker,
                rendezvousURL: rendezvousURL,
                timeoutSeconds: timeoutSeconds,
                rendererMode: rendererMode,
                buildIdentity: buildIdentity,
                rendererIntegration: rendererIntegration
            )
        }
    }

    private static func prepareRestart(
        marker: String,
        rendezvousURL: URL,
        stopSentinelURL: URL,
        timeoutSeconds: Double,
        rendererMode: RendererMode,
        buildIdentity: BuildIdentity,
        rendererIntegration: RendererIntegration
    ) async throws -> Report {
        let transport = NSXPCShellBrokerTransport()
        let client = Phase2HumanPTYShellSessionClient(transport: transport)
        let capabilityStore = Phase2DurableShellBrokerCapabilityStore()
        let secret = try capabilityStore.generateSecret()
        let capabilityID = UUID()
        let sessionID = UUID()
        let requestID = UUID()
        let now = Date()
        let plan = Phase2HumanPTYLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/sh",
            arguments: [
                "-c",
                "printf '%s\\n' \"$3\"; trap 'exit 0' TERM INT HUP; while [ ! -f \"$1\" ]; do sleep 0.05; done; sleep 120.25; printf '%s\\n' \"$2\"; while :; do sleep 1; done",
                "macscope-durable-restart-smoke",
                stopSentinelURL.path,
                "detached:\(marker)",
                "ready:\(marker)",
            ],
            initialSize: .defaultInteractive,
            transcriptLimits: .productionMaximum
        )
        let provisional = try await withTransportDeadline(
            timeoutSeconds: timeoutSeconds,
            operationDescription: "durable PREPARE launch",
            transport: transport
        ) {
            try await client.launchDurableProvisional(
                snapshot: .initial(sessionID: sessionID),
                plan: plan,
                capabilityID: capabilityID,
                capabilitySecret: secret,
                createdAt: now,
                expiresAt: now.addingTimeInterval(30 * 60)
            )
        }
        guard let identity = provisional.brokerResponse?.durableIdentity,
              identity.isStructurallyValid,
              identity.sessionID == sessionID,
              identity.launchRequest.requestID == requestID,
              identity.processIdentity.processIdentifier > 1,
              provisional.snapshot.sessionID == identity.sessionID,
              case .running(
                let provisionalRequestID,
                let provisionalProcessIdentifier
              ) = provisional.snapshot.state,
              provisionalRequestID == identity.launchRequest.requestID,
              provisionalProcessIdentifier == identity.processIdentity.processIdentifier else {
            throw SmokeError(description: "Durable PREPARE did not return an exact public identity.")
        }

        do {
            try capabilityStore.save(secret, for: capabilityID)
            try writeRendezvous(
                .init(
                    schemaVersion: Rendezvous.schemaVersion,
                    identity: identity,
                    transcriptCursor: provisional.snapshot.nextTranscriptSequence,
                    marker: marker
                ),
                to: rendezvousURL
            )
            let authentication = client.authenticationWire(identity: identity, secret: secret)
            _ = try await withTransportDeadline(
                timeoutSeconds: timeoutSeconds,
                operationDescription: "durable PREPARE commit",
                transport: transport
            ) {
                try await client.commitDurableSession(
                    authentication: authentication,
                    requestID: requestID
                )
            }
            var presentationSnapshot = provisional.snapshot
            var presentationEvents: [Phase2HumanPTYTranscriptEvent] = []
            _ = try await pollForUniqueMarker(
                client: client,
                snapshot: &presentationSnapshot,
                requestID: requestID,
                marker: "ready:\(marker)",
                markerDescription: "durable PREPARE renderer marker",
                acceptedEvents: &presentationEvents,
                timeoutSeconds: timeoutSeconds,
                transport: transport
            )
            let rendererEvidence = try await captureRendererEvidence(
                rendererMode: rendererMode,
                snapshot: presentationSnapshot,
                integration: rendererIntegration
            )
            await transport.reset()
            return try restartReport(
                mode: .prepare,
                identity: identity,
                buildIdentity: buildIdentity,
                rendererEvidence: rendererEvidence,
                transcriptCursor: provisional.snapshot.nextTranscriptSequence,
                bufferedMarker: nil,
                bufferedMarkerAcceptedCount: 0,
                transcriptCursorAdvanced: false,
                cleanupObservedProcessAbsent: false,
                capabilityRemoved: false,
                rendezvousRemoved: false
            )
        } catch {
            await cleanupFailedPrepare(
                client: client,
                transport: transport,
                snapshot: provisional.snapshot,
                identity: identity,
                secret: secret,
                capabilityStore: capabilityStore,
                rendezvousURL: rendezvousURL,
                timeoutSeconds: timeoutSeconds
            )
            await transport.reset()
            throw error
        }
    }

    private static func resumeRestart(
        marker: String,
        rendezvousURL: URL,
        timeoutSeconds: Double,
        rendererMode: RendererMode,
        buildIdentity: BuildIdentity,
        rendererIntegration: RendererIntegration
    ) async throws -> Report {
        let rendezvous = try readRendezvous(from: rendezvousURL)
        guard rendezvous.schemaVersion == Rendezvous.schemaVersion,
              rendezvous.marker == marker,
              rendezvous.identity.isStructurallyValid,
              rendezvous.transcriptCursor == rendezvous.identity.nextTranscriptSequence else {
            throw SmokeError(description: "Durable RESUME rendezvous identity or cursor mismatch.")
        }
        let identity = rendezvous.identity
        let capabilityStore = Phase2DurableShellBrokerCapabilityStore()
        guard let secret = try capabilityStore.load(for: identity.capabilityID) else {
            throw SmokeError(description: "Durable RESUME capability is absent from Keychain.")
        }
        let plan = Phase2HumanPTYLaunchPlan(
            sessionID: identity.sessionID,
            requestID: identity.launchRequest.requestID,
            executablePath: identity.launchRequest.executablePath,
            arguments: identity.launchRequest.arguments,
            workingDirectoryPath: identity.launchRequest.workingDirectoryPath,
            initialSize: .defaultInteractive,
            transcriptLimits: .productionMaximum
        )
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: identity.sessionID,
            state: .running(
                requestID: identity.launchRequest.requestID,
                processIdentifier: identity.processIdentity.processIdentifier
            ),
            launchPlan: plan,
            transcriptEvents: [],
            issues: []
        )
        let transport = NSXPCShellBrokerTransport()
        let client = Phase2HumanPTYShellSessionClient(transport: transport)
        defer { Task { await transport.reset() } }
        do {
            let recovered = try await withTransportDeadline(
                timeoutSeconds: timeoutSeconds,
                operationDescription: "durable RESUME recovery",
                transport: transport
            ) {
                try await client.recoverDurableSession(
                    snapshot: snapshot,
                    identity: identity,
                    capabilitySecret: secret
                )
            }
            guard recovered.brokerResponse?.durableIdentity == identity,
                  let recoveredCursor = recovered.brokerResponse?.nextTranscriptSequence,
                  recoveredCursor >= rendezvous.transcriptCursor else {
                throw SmokeError(description: "Durable RESUME returned a regressed transcript cursor.")
            }
            var recoveredSnapshot = recovered.snapshot
            var acceptedEvents: [Phase2HumanPTYTranscriptEvent] = []
            let bufferedMarker = "detached:\(marker)"
            let acceptedMarkerCount = try await pollForUniqueMarker(
                client: client,
                snapshot: &recoveredSnapshot,
                requestID: identity.launchRequest.requestID,
                marker: bufferedMarker,
                markerDescription: "detached durable transcript marker",
                acceptedEvents: &acceptedEvents,
                timeoutSeconds: timeoutSeconds,
                transport: transport
            )
            let resumedCursor = recoveredSnapshot.nextTranscriptSequence
            guard resumedCursor > rendezvous.transcriptCursor else {
                throw SmokeError(description: "Durable RESUME transcript cursor did not advance after accepting buffered output.")
            }
            guard recoveredSnapshot.sessionID == identity.sessionID,
                  case .running(let recoveredRequestID, let recoveredProcessIdentifier) = recoveredSnapshot.state,
                  recoveredRequestID == identity.launchRequest.requestID,
                  recoveredProcessIdentifier == identity.processIdentity.processIdentifier else {
                throw SmokeError(
                    description: "Durable RESUME changed the recovered process coordinate."
                )
            }
            let rendererEvidence = try await captureRendererEvidence(
                rendererMode: rendererMode,
                snapshot: recoveredSnapshot,
                integration: rendererIntegration
            )
            try await authenticatedCleanup(
                client: client,
                snapshot: recoveredSnapshot,
                identity: identity,
                secret: secret,
                capabilityStore: capabilityStore,
                rendezvousURL: rendezvousURL,
                timeoutSeconds: timeoutSeconds,
                transport: transport,
                reason: "installedRestartSmoke"
            )
            return try restartReport(
                mode: .resume,
                identity: identity,
                buildIdentity: buildIdentity,
                rendererEvidence: rendererEvidence,
                transcriptCursor: resumedCursor,
                bufferedMarker: bufferedMarker,
                bufferedMarkerAcceptedCount: acceptedMarkerCount,
                transcriptCursorAdvanced: true,
                acceptedTranscriptEventCount: acceptedEvents.count,
                cleanupObservedProcessAbsent: true,
                capabilityRemoved: true,
                rendezvousRemoved: true
            )
        } catch {
            // Preserve the credential and rendezvous until the broker proves exact-session
            // cleanup. This best-effort attempt closes failures after attach/status while the
            // external harness retains CLEANUP as a second independent recovery attempt.
            try? await authenticatedCleanup(
                client: client,
                snapshot: snapshot,
                identity: identity,
                secret: secret,
                capabilityStore: capabilityStore,
                rendezvousURL: rendezvousURL,
                timeoutSeconds: timeoutSeconds,
                transport: transport,
                reason: "installedRestartResumeFailure"
            )
            throw error
        }
    }

    private static func cleanupRestart(
        marker: String,
        rendezvousURL: URL,
        timeoutSeconds: Double,
        rendererMode: RendererMode,
        buildIdentity: BuildIdentity,
        rendererIntegration: RendererIntegration
    ) async throws -> Report {
        let rendezvous = try readRendezvous(from: rendezvousURL)
        guard rendezvous.schemaVersion == Rendezvous.schemaVersion,
              rendezvous.marker == marker,
              rendezvous.identity.isStructurallyValid else {
            throw SmokeError(description: "Durable CLEANUP rendezvous identity mismatch.")
        }
        let identity = rendezvous.identity
        let capabilityStore = Phase2DurableShellBrokerCapabilityStore()
        guard let secret = try capabilityStore.load(for: identity.capabilityID) else {
            throw SmokeError(description: "Durable CLEANUP capability is absent from Keychain.")
        }
        let transport = NSXPCShellBrokerTransport()
        defer { Task { await transport.reset() } }
        let client = Phase2HumanPTYShellSessionClient(transport: transport)
        let snapshot = restartSnapshot(identity: identity)
        var cleanupSnapshot = snapshot
        let rendererEvidenceResult: Result<RendererEvidence, Error>
        do {
            let recovered = try await withTransportDeadline(
                timeoutSeconds: timeoutSeconds,
                operationDescription: "durable CLEANUP recovery",
                transport: transport
            ) {
                try await client.recoverDurableSession(
                    snapshot: snapshot,
                    identity: identity,
                    capabilitySecret: secret
                )
            }
            guard recovered.brokerResponse?.durableIdentity == identity,
                  recovered.snapshot.sessionID == identity.sessionID,
                  case .running(
                    let recoveredRequestID,
                    let recoveredProcessIdentifier
                  ) = recovered.snapshot.state,
                  recoveredRequestID == identity.launchRequest.requestID,
                  recoveredProcessIdentifier == identity.processIdentity.processIdentifier else {
                throw SmokeError(
                    description: "Durable CLEANUP changed the recovered process coordinate."
                )
            }
            cleanupSnapshot = recovered.snapshot
            var presentationEvents: [Phase2HumanPTYTranscriptEvent] = []
            _ = try await pollForUniqueMarker(
                client: client,
                snapshot: &cleanupSnapshot,
                requestID: identity.launchRequest.requestID,
                marker: "ready:\(marker)",
                markerDescription: "durable CLEANUP renderer marker",
                acceptedEvents: &presentationEvents,
                timeoutSeconds: timeoutSeconds,
                transport: transport
            )
            rendererEvidenceResult = .success(try await captureRendererEvidence(
                rendererMode: rendererMode,
                snapshot: cleanupSnapshot,
                integration: rendererIntegration
            ))
        } catch {
            rendererEvidenceResult = .failure(error)
        }
        try await authenticatedCleanup(
            client: client,
            snapshot: cleanupSnapshot,
            identity: identity,
            secret: secret,
            capabilityStore: capabilityStore,
            rendezvousURL: rendezvousURL,
            timeoutSeconds: timeoutSeconds,
            transport: transport,
            reason: "installedRestartHarnessCleanup"
        )
        let rendererEvidence = try rendererEvidenceResult.get()
        return try restartReport(
            mode: .cleanup,
            identity: identity,
            buildIdentity: buildIdentity,
            rendererEvidence: rendererEvidence,
            transcriptCursor: rendezvous.transcriptCursor,
            bufferedMarker: nil,
            bufferedMarkerAcceptedCount: 0,
            transcriptCursorAdvanced: false,
            cleanupObservedProcessAbsent: true,
            capabilityRemoved: true,
            rendezvousRemoved: true
        )
    }

    private static func authenticatedCleanup(
        client: Phase2HumanPTYShellSessionClient,
        snapshot: Phase2HumanPTYSessionSnapshot,
        identity: Phase2DurableShellBrokerIdentity,
        secret: Phase2DurableShellBrokerCapabilitySecret,
        capabilityStore: Phase2DurableShellBrokerCapabilityStore,
        rendezvousURL: URL,
        timeoutSeconds: Double,
        transport: NSXPCShellBrokerTransport,
        reason: String
    ) async throws {
        try await withTransportDeadline(
            timeoutSeconds: min(timeoutSeconds, 5),
            operationDescription: "authenticated durable cleanup",
            transport: transport
        ) {
            try await client.cleanupDurableSession(
                snapshot: snapshot,
                identity: identity,
                capabilitySecret: secret,
                reason: reason
            )
        }
        try await waitForProcessAbsence(
            identity.processIdentity.processIdentifier,
            timeoutSeconds: min(timeoutSeconds, 5)
        )
        // Destructive local artifact removal occurs only after broker cleanup proof and process
        // absence. If either removal fails, retained evidence permits another CLEANUP attempt.
        _ = try capabilityStore.delete(for: identity.capabilityID)
        guard try capabilityStore.load(for: identity.capabilityID) == nil else {
            throw SmokeError(description: "Authenticated cleanup left the Keychain capability.")
        }
        try FileManager.default.removeItem(at: rendezvousURL)
        guard !FileManager.default.fileExists(atPath: rendezvousURL.path) else {
            throw SmokeError(description: "Authenticated cleanup left the rendezvous.")
        }
    }

    /// PREPARE must retain its public rendezvous and Keychain capability whenever exact cleanup
    /// cannot be proved. The independent CLEANUP launch can then authenticate and recover the
    /// durable shell instead of inheriting an orphaned process with its only authority deleted.
    private static func cleanupFailedPrepare(
        client: Phase2HumanPTYShellSessionClient,
        transport: NSXPCShellBrokerTransport,
        snapshot: Phase2HumanPTYSessionSnapshot,
        identity: Phase2DurableShellBrokerIdentity,
        secret: Phase2DurableShellBrokerCapabilitySecret,
        capabilityStore: Phase2DurableShellBrokerCapabilityStore,
        rendezvousURL: URL,
        timeoutSeconds: Double
    ) async {
        do {
            try await withTransportDeadline(
                timeoutSeconds: min(timeoutSeconds, 5),
                operationDescription: "durable PREPARE failure cleanup",
                transport: transport
            ) {
                try await client.cleanupDurableSession(
                    snapshot: snapshot,
                    identity: identity,
                    capabilitySecret: secret,
                    reason: "installedRestartPrepareFailure"
                )
            }
            try await waitForProcessAbsence(
                identity.processIdentity.processIdentifier,
                timeoutSeconds: min(timeoutSeconds, 5)
            )
        } catch {
            return
        }

        _ = try? capabilityStore.delete(for: identity.capabilityID)
        if FileManager.default.fileExists(atPath: rendezvousURL.path) {
            try? FileManager.default.removeItem(at: rendezvousURL)
        }
    }

    private static func waitForProcessAbsence(
        _ processIdentifier: Int32,
        timeoutSeconds: Double
    ) async throws {
        let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
        while processExists(processIdentifier), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard !processExists(processIdentifier) else {
            throw SmokeError(description: "Authenticated cleanup did not observe the exact shell PID absent.")
        }
    }

    private static func restartSnapshot(
        identity: Phase2DurableShellBrokerIdentity
    ) -> Phase2HumanPTYSessionSnapshot {
        let plan = Phase2HumanPTYLaunchPlan(
            sessionID: identity.sessionID,
            requestID: identity.launchRequest.requestID,
            executablePath: identity.launchRequest.executablePath,
            arguments: identity.launchRequest.arguments,
            workingDirectoryPath: identity.launchRequest.workingDirectoryPath,
            initialSize: .defaultInteractive,
            transcriptLimits: .productionMaximum
        )
        return Phase2HumanPTYSessionSnapshot(
            sessionID: identity.sessionID,
            state: .running(
                requestID: identity.launchRequest.requestID,
                processIdentifier: identity.processIdentity.processIdentifier
            ),
            launchPlan: plan,
            transcriptEvents: [],
            issues: []
        )
    }

    private static func restartReport(
        mode: Mode,
        identity: Phase2DurableShellBrokerIdentity,
        buildIdentity: BuildIdentity,
        rendererEvidence: RendererEvidence,
        transcriptCursor: UInt64,
        bufferedMarker: String? = nil,
        bufferedMarkerAcceptedCount: Int = 0,
        transcriptCursorAdvanced: Bool = false,
        acceptedTranscriptEventCount: Int = 0,
        cleanupObservedProcessAbsent: Bool,
        capabilityRemoved: Bool,
        rendezvousRemoved: Bool
    ) throws -> Report {
        Report(
            schemaVersion: schemaVersion,
            status: .passed,
            generatedAtUnixMilliseconds: unixMilliseconds(),
            appExecutablePath: Bundle.main.executableURL?.path ?? "",
            appExecutableSHA256: try appExecutableSHA256(),
            sourceCommit: buildIdentity.sourceCommit,
            sourceTree: buildIdentity.sourceTree,
            buildProvenanceSHA256: buildIdentity.buildProvenanceSHA256,
            rendererEvidence: rendererEvidence,
            shellBrokerServiceIdentifier: Phase2ShellBrokerProtocolIdentity.serviceIdentifier,
            shellBrokerWireProtocol: Phase2ShellBrokerProtocolIdentity.wireProtocol,
            supportedCommands: Phase2ShellBrokerCommandKind.allCases.map(\.rawValue),
            launchedProcessIdentifier: identity.processIdentity.processIdentifier,
            observedReply: bufferedMarker,
            acceptedTranscriptEventCount: acceptedTranscriptEventCount,
            reconnectAcceptedTranscriptEventCount: 0,
            cleanupObservedProcessAbsent: cleanupObservedProcessAbsent,
            mode: mode.rawValue,
            brokerIncarnationID: identity.brokerIncarnationID,
            processStartTimeUnixNanoseconds: identity.processIdentity.processStartTimeUnixNanoseconds,
            executablePath: identity.processIdentity.executablePath,
            processGroupIdentifier: identity.processIdentity.processGroupIdentifier,
            transcriptCursor: transcriptCursor,
            bufferedMarker: bufferedMarker,
            bufferedMarkerAcceptedCount: bufferedMarkerAcceptedCount,
            transcriptCursorAdvanced: transcriptCursorAdvanced,
            capabilityRemoved: capabilityRemoved,
            rendezvousRemoved: rendezvousRemoved,
            error: nil
        )
    }

    static func rendererMode(environment: [String: String]) throws -> RendererMode {
        guard let rawMode = environment[rendererModeEnvironmentKey],
              let mode = RendererMode(rawValue: rawMode) else {
            throw SmokeError(description: "Installed renderer smoke mode is missing or invalid.")
        }
        return mode
    }

    static func validateRendererEvidence(
        request: RendererEvidenceRequest,
        observation: RendererRuntimeEvidence
    ) throws -> RendererEvidence {
        guard request.shellProcessIdentifier > 1 else {
            throw SmokeError(description: "Installed renderer request has an invalid shell PID.")
        }
        guard observation.generation == request.generation else {
            throw SmokeError(description: "Installed renderer evidence has a stale generation.")
        }
        guard observation.requestedMode == request.requestedMode else {
            throw SmokeError(description: "Installed renderer evidence changed the requested mode.")
        }
        guard observation.shellSessionID == request.shellSessionID,
              observation.shellRequestID == request.shellRequestID,
              observation.shellProcessIdentifier == request.shellProcessIdentifier else {
            throw SmokeError(
                description: "Installed renderer evidence does not match the exact shell coordinate."
            )
        }
        guard observation.selectedBackend == request.requestedMode.expectedBackend,
              observation.fallbackReason == request.requestedMode.expectedFallbackReason else {
            throw SmokeError(
                description: "Installed renderer evidence did not prove the requested backend."
            )
        }
        guard observation.rendererPresented else {
            throw SmokeError(description: "Installed renderer evidence omitted presentation.")
        }
        guard !observation.transcriptOnlyFallbackPresented else {
            throw SmokeError(
                description: "Transcript-only fallback cannot satisfy installed renderer proof."
            )
        }
        return RendererEvidence(
            requestedMode: observation.requestedMode,
            selectedBackend: observation.selectedBackend,
            fallbackReason: observation.fallbackReason,
            rendererPresented: observation.rendererPresented,
            transcriptOnlyFallbackPresented: observation.transcriptOnlyFallbackPresented,
            shellSessionID: observation.shellSessionID,
            shellRequestID: observation.shellRequestID,
            shellProcessIdentifier: observation.shellProcessIdentifier
        )
    }

    static func validateCleanupObservedProcessAbsent(_ observed: Bool?) throws {
        guard observed == true else {
            throw SmokeError(
                description: "Installed ShellBroker cleanup omitted exact process-absence proof."
            )
        }
    }

    static func validateRendererPresentationLease(
        request: RendererEvidenceRequest,
        lease: RendererPresentationLease
    ) throws {
        let binding = lease.rendererBinding
        guard lease.requestGeneration == request.generation else {
            throw SmokeError(description: "Installed renderer presentation has a stale request generation.")
        }
        guard binding.sessionID == request.shellSessionID,
              binding.requestID == request.shellRequestID,
              binding.shellBrokerProcessIdentifier == request.shellProcessIdentifier else {
            throw SmokeError(
                description: "Installed renderer presentation does not match the exact shell coordinate."
            )
        }
        switch (request.requestedMode, binding.generation) {
        case let (.defaultFullGhosttySurface, .exact(generation)) where generation > 0:
            break
        case (.forcedLegacyGridRecoveryOverride, .notAllocated):
            break
        default:
            throw SmokeError(
                description: "Installed renderer presentation has the wrong generation binding."
            )
        }
    }

    private static func captureRendererEvidence(
        rendererMode: RendererMode,
        snapshot: Phase2HumanPTYSessionSnapshot,
        integration: RendererIntegration
    ) async throws -> RendererEvidence {
        guard case .running(let shellRequestID, let shellProcessIdentifier) = snapshot.state,
              shellProcessIdentifier > 1 else {
            throw SmokeError(
                description: "Installed renderer presentation requires an exact running shell."
            )
        }
        let request = RendererEvidenceRequest(
            requestedMode: rendererMode,
            generation: UUID(),
            shellSessionID: snapshot.sessionID,
            shellRequestID: shellRequestID,
            shellProcessIdentifier: shellProcessIdentifier
        )
        let lease = try await integration.presentationProvider(request, snapshot)
        try validateRendererPresentationLease(request: request, lease: lease)
        let observation = try await integration.evidenceProvider(request, lease)
        return try validateRendererEvidence(request: request, observation: observation)
    }

    private static func loadEmbeddedBuildIdentity() throws -> BuildIdentity {
        guard let resourcesURL = Bundle.main.resourceURL else {
            throw SmokeError(description: "Installed app resource directory is unavailable.")
        }
        return try loadBuildIdentity(
            provenanceURL: resourcesURL.appendingPathComponent(
                buildProvenanceResourceName,
                isDirectory: false
            )
        )
    }

    static func loadBuildIdentity(provenanceURL: URL) throws -> BuildIdentity {
        let data = try readBoundedOrdinaryFile(
            at: provenanceURL,
            maximumBytes: maximumBuildProvenanceBytes
        )
        let provenance: EmbeddedBuildProvenance
        do {
            provenance = try JSONDecoder().decode(EmbeddedBuildProvenance.self, from: data)
        } catch {
            throw SmokeError(description: "Installed Release provenance is malformed.")
        }
        guard provenance.schemaVersion == 1,
              provenance.qualificationEligible,
              provenance.configuration == "Release",
              provenance.repositoryClean,
              provenance.ghosttySurfaceCompilationCondition == "MACSCOPE_FULL_GHOSTTY_SURFACE",
              isLowercaseHex(provenance.sourceCommit, length: 40),
              isLowercaseHex(provenance.sourceTree, length: 40) else {
            throw SmokeError(
                description: "Installed Release provenance is not an eligible full-surface build."
            )
        }
        return BuildIdentity(
            sourceCommit: provenance.sourceCommit,
            sourceTree: provenance.sourceTree,
            buildProvenanceSHA256: sha256Hex(data)
        )
    }

    private static func readBoundedOrdinaryFile(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        guard url.isFileURL, url.path.hasPrefix("/"), maximumBytes > 0 else {
            throw SmokeError(description: "Installed Release provenance path is invalid.")
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw SmokeError(description: "Installed Release provenance is missing or indirect.")
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size > 0,
              metadata.st_size <= off_t(maximumBytes) else {
            throw SmokeError(
                description: "Installed Release provenance is not one bounded ordinary file."
            )
        }

        let expectedByteCount = Int(metadata.st_size)
        var data = Data(count: expectedByteCount)
        var offset = 0
        while offset < expectedByteCount {
            let readCount = data.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    expectedByteCount - offset
                )
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount > 0 else {
                throw SmokeError(description: "Installed Release provenance read was incomplete.")
            }
            offset += readCount
        }

        var trailingByte: UInt8 = 0
        let trailingCount = Darwin.read(descriptor, &trailingByte, 1)
        guard trailingCount == 0 else {
            throw SmokeError(description: "Installed Release provenance changed while reading.")
        }
        var finalMetadata = stat()
        guard Darwin.fstat(descriptor, &finalMetadata) == 0,
              finalMetadata.st_dev == metadata.st_dev,
              finalMetadata.st_ino == metadata.st_ino,
              finalMetadata.st_mode & S_IFMT == S_IFREG,
              finalMetadata.st_nlink == 1,
              finalMetadata.st_size == metadata.st_size else {
            throw SmokeError(description: "Installed Release provenance identity changed while reading.")
        }
        return data
    }

    private static func isLowercaseHex(_ value: String, length: Int) -> Bool {
        let bytes = value.utf8
        guard bytes.count == length else { return false }
        return bytes.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeRendezvous(_ rendezvous: Rendezvous, to url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw SmokeError(description: "Rendezvous path must be absolute.")
        }
        let manager = FileManager.default
        let parent = url.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(rendezvous)
        guard data.count <= maximumReportBytes else {
            throw SmokeError(description: "Rendezvous exceeded its size bound.")
        }
        try data.write(to: url, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard (try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            throw SmokeError(description: "Rendezvous permissions are not 0600.")
        }
    }

    private static func readRendezvous(from url: URL) throws -> Rendezvous {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true,
              values.isRegularFile == true,
              (values.fileSize ?? maximumReportBytes + 1) <= maximumReportBytes else {
            throw SmokeError(description: "Rendezvous is not a bounded regular file.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw SmokeError(description: "Rendezvous ownership or permissions mismatch.")
        }
        return try JSONDecoder().decode(Rendezvous.self, from: Data(contentsOf: url))
    }

    private static func processExists(_ processIdentifier: Int32) -> Bool {
        guard processIdentifier > 1 else { return false }
        if Darwin.kill(processIdentifier, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func waitForCooperativeStop(
        at url: URL,
        timeoutSeconds: Double
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard values.isSymbolicLink != true,
                      values.isRegularFile == true,
                      values.fileSize == 0,
                      (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                    throw SmokeError(description: "PREPARE stop sentinel identity mismatch.")
                }
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw SmokeError(description: "Timed out waiting for cooperative PREPARE stop.")
    }

    private static func pollForReply(
        client: Phase2HumanPTYShellSessionClient,
        snapshot: inout Phase2HumanPTYSessionSnapshot,
        requestID: UUID,
        marker: String,
        acceptedEvents: inout [Phase2HumanPTYTranscriptEvent],
        timeoutSeconds: Double,
        transport: NSXPCShellBrokerTransport
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let pollSnapshot = snapshot
            let remainingDuration = max(0, deadline.timeIntervalSinceNow)
            let poll = try await withTransportDeadline(
                timeoutSeconds: remainingDuration,
                operationDescription: "installed ShellBroker transcript poll",
                transport: transport
            ) {
                try await client.pollTranscript(
                    snapshot: pollSnapshot,
                    requestID: requestID,
                    maximumEvents: 16,
                    maximumBytes: 4_096,
                    timeoutMilliseconds: 50
                )
            }
            snapshot = poll.snapshot
            acceptedEvents.append(contentsOf: poll.acceptedTranscriptEvents)
            if let reply = replyText(in: snapshot.transcriptEvents, marker: marker) {
                return reply
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw SmokeError(description: "Timed out waiting for installed ShellBroker transcript reply.")
    }

    private static func pollForUniqueMarker(
        client: Phase2HumanPTYShellSessionClient,
        snapshot: inout Phase2HumanPTYSessionSnapshot,
        requestID: UUID,
        marker: String,
        markerDescription: String,
        acceptedEvents: inout [Phase2HumanPTYTranscriptEvent],
        timeoutSeconds: Double,
        transport: NSXPCShellBrokerTransport
    ) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let pollSnapshot = snapshot
            let remainingDuration = max(0, deadline.timeIntervalSinceNow)
            let poll = try await withTransportDeadline(
                timeoutSeconds: remainingDuration,
                operationDescription: markerDescription,
                transport: transport
            ) {
                try await client.pollTranscript(
                    snapshot: pollSnapshot,
                    requestID: requestID,
                    maximumEvents: 32,
                    maximumBytes: 4_096,
                    timeoutMilliseconds: 50
                )
            }
            snapshot = poll.snapshot
            acceptedEvents.append(contentsOf: poll.acceptedTranscriptEvents)
            let output = acceptedEvents.reduce(into: Data()) { data, event in
                guard case .output(_, let bytes) = event.payload else { return }
                data.append(contentsOf: bytes)
            }
            let text = String(decoding: output, as: UTF8.self)
            let markerCount = text.components(separatedBy: marker).count - 1
            if markerCount == 1 { return markerCount }
            if markerCount > 1 {
                throw SmokeError(description: "ShellBroker delivered the \(markerDescription) more than once.")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw SmokeError(description: "Timed out waiting for the \(markerDescription).")
    }

    private static func replyText(
        in events: [Phase2HumanPTYTranscriptEvent],
        marker: String
    ) -> String? {
        let expected = "reply:\(marker)"
        for event in events {
            guard case .output(_, let bytes) = event.payload else { continue }
            let text = String(decoding: bytes, as: UTF8.self)
            if text.contains(expected) {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func failureReport(error: Error, buildIdentity: BuildIdentity?) -> Report {
        Report(
            schemaVersion: schemaVersion,
            status: .failed,
            generatedAtUnixMilliseconds: unixMilliseconds(),
            appExecutablePath: Bundle.main.executableURL?.path ?? "",
            appExecutableSHA256: (try? appExecutableSHA256()) ?? "",
            sourceCommit: buildIdentity?.sourceCommit,
            sourceTree: buildIdentity?.sourceTree,
            buildProvenanceSHA256: buildIdentity?.buildProvenanceSHA256,
            rendererEvidence: nil,
            shellBrokerServiceIdentifier: Phase2ShellBrokerProtocolIdentity.serviceIdentifier,
            shellBrokerWireProtocol: Phase2ShellBrokerProtocolIdentity.wireProtocol,
            supportedCommands: Phase2ShellBrokerCommandKind.allCases.map(\.rawValue),
            launchedProcessIdentifier: nil,
            observedReply: nil,
            acceptedTranscriptEventCount: 0,
            reconnectAcceptedTranscriptEventCount: 0,
            cleanupObservedProcessAbsent: false,
            mode: nil,
            brokerIncarnationID: nil,
            processStartTimeUnixNanoseconds: nil,
            executablePath: nil,
            processGroupIdentifier: nil,
            transcriptCursor: nil,
            bufferedMarker: nil,
            bufferedMarkerAcceptedCount: nil,
            transcriptCursorAdvanced: nil,
            capabilityRemoved: nil,
            rendezvousRemoved: nil,
            error: String(describing: error)
        )
    }

    private static func write(_ report: Report, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        guard data.count <= maximumReportBytes else {
            throw SmokeError(description: "Installed shell smoke report exceeded \(maximumReportBytes) bytes.")
        }
        try data.write(to: url, options: [.atomic])
    }

    private static func appExecutableSHA256() throws -> String {
        guard let url = Bundle.main.executableURL else {
            throw SmokeError(description: "App executable URL unavailable.")
        }
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Bounds one exact transport-backed operation. Cancelling the losing task is insufficient for
    /// an XPC continuation that has not replied, so timeout and caller cancellation both reset the
    /// same transport and force every registered pending continuation to resolve.
    static func withTransportDeadline<Value: Sendable>(
        timeoutSeconds: Double,
        operationDescription: String,
        transport: any ShellBrokerXPCTransport,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await Phase2InstalledSmokeOperationDeadline.perform(
            timeoutSeconds: timeoutSeconds,
            operationDescription: operationDescription,
            reset: {
                await transport.reset()
            },
            operation: operation
        )
    }

    private static func parseTimeout(_ value: String?) -> Double {
        guard let value,
              let parsed = Double(value),
              parsed >= 1,
              parsed <= 30
        else { return defaultTimeoutSeconds }
        return parsed
    }

    private static func unixMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
