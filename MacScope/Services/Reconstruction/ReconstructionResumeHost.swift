import AppKit
import Darwin
import Foundation

/// Explicit fixture host only. It composes production jobs with a deterministic in-process
/// inference provider and the ordinary signed analysis/source workers. It never contacts MTPLX.
@MainActor
enum ReconstructionResumeHost {
    static let selector = "--headless-reconstruction-resume-host"
    static let points = ["executingReads", "modelRound", "retrieveEvidence", "sourceReplyPublished",
        "sourceRevisionCommitted", "buildCompleted", "behaviorFailure", "repairAdmission",
        "repairReplyPublished", "completedCheckpoint"]

    struct Request: Codable, Sendable {
        let domain: String
        let workspaceID: UUID
        let projectID: UUID
        let jobID: UUID
    }
    struct Report: Codable, Sendable {
        let pid: Int32
        let state: String
        let freshSourceCalls: Int
        let freshRoundCalls: Int
        let replayedReplies: UInt64
        let replayedNativePromptFacts: Int
        let activePackageMigrated: Bool
        let liveHistoryRoundCount: Int
        let liveHistoryReplayedRoundCount: Int
        let completedPackageHasNoReplayProvenance: Bool
        let sourceRevisions: Int
        let evaluations: Int
        let harnessPassed: Int
        let packageReopened: Bool
        let activationProhibited: Bool
        let quitIgnoredDuringExecution: Bool
        let quitAllowedWhenIdle: Bool
    }
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func runIfRequested(arguments: [String], environment: [String: String]) -> Bool {
        guard arguments.dropFirst().contains(where: { $0.hasPrefix(selector) }) else { return false }
        guard environment["MACSCOPE_HEADLESS_HOST"] == "1" else { fail("headless-reconstruction-host-flag-required", code: EX_USAGE) }
        guard arguments.count == 4, arguments[1] == selector,
              arguments[2].hasPrefix("/"), arguments[3] == "resume" || points.contains(arguments[3]) else {
            fail("headless-reconstruction-host-arguments-invalid", code: EX_USAGE)
        }
        let root: URL
        do { root = try admitRoot(arguments[2]) }
        catch { fail("headless-reconstruction-host-owned-root-required", code: EX_USAGE) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 600) {
            fail("headless-reconstruction-host-deadline", code: EX_TEMPFAIL)
        }
        Task { @MainActor in
            do {
                let report = try await run(root: root, point: arguments[3])
                let bytes = try ReconstructionCanonicalJSON.encode(report)
                try bytes.write(to: root.appendingPathComponent("result.json"), options: .atomic)
                FileHandle.standardOutput.write(bytes)
                Darwin.exit(EXIT_SUCCESS)
            } catch { fail("headless-reconstruction-host-failed: \(error)", code: EX_SOFTWARE) }
        }
        // AppKit's Quit dispatch requires the actual main thread/run loop. dispatchMain() exits
        // that thread on macOS and runs MainActor work on a replacement thread, which cannot
        // establish that applicationShouldTerminate was called. Activation remains prohibited.
        NSApplication.shared.run()
        fail("headless-reconstruction-host-runloop-ended", code: EX_SOFTWARE)
    }

    private static func admitRoot(_ path: String) throws -> URL {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        var metadata = stat()
        guard root.standardizedFileURL.path == path, root.resolvingSymlinksInPath().path == path,
              lstat(path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == getuid(), (metadata.st_mode & 0o077) == 0,
              root.lastPathComponent.hasPrefix("t27-resume-") else {
            throw Failure(description: "owned-root-required")
        }
        return root
    }

    nonisolated private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8)); Darwin.exit(code)
    }

    private static func run(root: URL, point: String) async throws -> Report {
        let request = try JSONDecoder().decode(Request.self, from: CLIRunner.loadScript(
            at: root.appendingPathComponent("fixture-request.json"), maximumBytes: 4_096))
        guard request.domain == "reconstruction.resume.fixture.v1" else { throw Failure(description: "invalid-fixture-request") }
        var path = root.appendingPathComponent("workspace.sqlite").path
        let isNew = !FileManager.default.fileExists(atPath: path)
        var (rowID, owner) = try makeOwner(path: path, root: root, request: request, isNew: isNew)
        var original: ReconstructionSourceOriginalSession?
        let broker = NSXPCShellBrokerTransport()
        if isNew {
            let preparation = ReconstructionSourceOriginalSession(workflow: .init(transport: broker,
                toolAuthority: try .capture()), stageParent: root)
            original = preparation
            let candidate = try await preparation.prepare()
            let imported = await ReconstructionCorpusImporter().ingest(
                selections: [.init(rootURL: candidate.executableURL, roles: [.primaryTarget])],
                projectID: request.projectID, cancellation: ReconstructionCancellation())
            guard imported.failures.isEmpty, let occurrence = imported.occurrences.first(where: { $0.kind == .machOImage }) else {
                throw Failure(description: "fixture-import-failed")
            }
            let artifact = ReconstructionArtifactCoordinate(occurrenceID: occurrence.occurrenceID, contentIdentity: occurrence.contentIdentity)
            let manifest = try ReconstructionCorpusManifest(reconstructionProjectID: request.projectID,
                artifacts: imported.occurrences, relations: imported.relations, canonicalSHA256: imported.canonicalManifestSHA256)
            _ = try await owner.commitCorpus(workspaceID: request.workspaceID, mutation: .init(
                projectID: request.projectID, expectedCurrentManifestSHA256: nil,
                successorManifest: manifest, attachmentSources: imported.attachmentSources))
            _ = try await owner.commitInitialJob(workspaceID: request.workspaceID, mutation: .init(
                jobID: request.jobID, projectID: request.projectID, selectedOccurrenceIDs: [occurrence.occurrenceID],
                objective: "Reconstruct the fixed C sample; repair the wrapping revision after its captured behavioral mismatch.",
                budget: try .init(maxRounds: 8, maxTasks: 256, maxEvidenceRecords: 512, maxEncodedBytes: 8_388_608),
                focus: .artifact(artifact), sourceProfileID: ReconstructionSourceExecutionTaskContract.profileID))
            try await preparation.bind(projectID: request.projectID, jobID: request.jobID, importedArtifact: artifact)
            try await ReconstructionSourceOriginalSessionRegistry.shared.register(workspaceID: request.workspaceID,
                jobID: request.jobID, session: preparation)
        }
        var activePackageMigrated = false
        if point == "resume" {
            let arrival = try JSONDecoder().decode([String: String].self,
                from: Data(contentsOf: root.appendingPathComponent("kill-arrived.json")))
            if arrival["point"] == "sourceReplyPublished" {
                // The only source of the imported database is the portable package, including
                // the active reply journal. The original database remains preserved untouched.
                let state = try await owner.load(workspaceID: request.workspaceID)
                let sources = try await owner.availableDurableAttachmentSources(workspaceID: request.workspaceID)
                await owner.revoke()
                let prior = try WorkspaceDatabase(path: path)
                let components = try prior.packageComponents(workspaceID: rowID, documentID: UUID(),
                    inputCopyingDecision: .copyInputsIntoPackage,
                    bookmarkResolutionDecision: .resolveStoredBookmarks, phase2ShellSession: nil)
                let package = root.appendingPathComponent("ActiveReply.mscope")
                try MacScopeDocumentPackage.writePackage(components.manifest,
                    attachmentsByBinaryID: components.attachmentsByBinaryID, reconstructionState: state,
                    reconstructionAttachmentSources: sources, to: package)
                let opened = try MacScopeDocumentPackage.openPackage(from: package)
                guard opened.reconstructionState == state,
                      opened.manifest.requiredReaderFeatures == [WorkspacePackageManifest.reconstructionReplayReaderFeature] else {
                    throw Failure(description: "fixture-active-package-replay-mismatch")
                }
                path = root.appendingPathComponent("package-imported.sqlite").path
                let imported = try WorkspaceDatabase(path: path)
                try imported.applySchema()
                let persisted = try imported.importPackage(from: package)
                guard let importedRow = persisted.workspace.id,
                      try imported.loadReconstructionState(workspaceID: request.workspaceID) == state else {
                    throw Failure(description: "fixture-active-package-import-mismatch")
                }
                rowID = importedRow
                // Mirror the production open path (ReconstructionWorkspaceDatabaseRuntime): the
                // package's verified reconstruction attachments, including the original executable
                // the job admitted, are published into the imported database's own durable vault.
                // Raw importPackage copies rows only; without this the resumed job has no retained
                // original bytes (reconstructionAttachmentSourcesUnavailable).
                imported.configureReconstructionAttachmentVault(rootURL: root.appendingPathComponent("imported-vault"))
                for manifest in state.corpusManifests {
                    let identities = Set(manifest.artifacts.map(\.contentIdentity))
                    let sources = opened.reconstructionAttachmentSources.filter { identities.contains($0.contentIdentity) }
                    _ = try imported.publishDurableReconstructionAttachmentSources(sources, for: manifest)
                }
                owner = ReconstructionDatabaseOwner(database: imported,
                    attachmentVaultRootURL: root.appendingPathComponent("imported-vault"))
                activePackageMigrated = true
            }
        }
        ReconstructionResumeFaultInjection.shared.install(root: root, point: point)
        let controller = try await makeController()
        let calls = ReconstructionResumeCallJournal(root: root)
        let provider = ReconstructionResumeScriptedProvider(calls: calls)
        let inference = Phase2ReadyInferenceCoordinator(controller: controller,
            reconstructionR2ProviderFactory: { _ in provider }, reconstructionSourceProviderFactory: { _ in provider })
        let builder = ReconstructionProductionComposition.unsealedHostJobSessionFactoryBuilderForTesting(
            nativeDecompilerRuntime: .productionShared,
            modelProducerContext: .init(macScopeBuildIdentity: ReconstructionSourceInferenceContract.sha256(Data("t27-loopback-host".utf8)),
                macScopeSourceIdentity: ReconstructionSourceInferenceContract.sha256(Data("t27-loopback-source".utf8)),
                operationIdentity: ReconstructionProductionTaskContract.modelRound,
                registryIdentity: Phase2ReconstructionProtocolArtifacts.make().toolRegistry.identity.sha256,
                protocolIdentity: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest, toolchainIdentity: "T27-fixture"),
            sourceTransport: { ReconstructionResumeSourceTransport(inner: $0) })
        let store = WorkspaceStore(workspaceName: "T27 restart fixture", snapshot: .init(binaries: [], analysisBySlot: [:]),
            engine: AnalysisEngine(), autosaveScheduler: nil, workspaceID: request.workspaceID)
        let before = try await owner.load(workspaceID: request.workspaceID)
        guard let job = before.jobs.first(where: { $0.jobID == request.jobID }),
              let checkpoint = before.checkpoints.first(where: { $0.checkpointID == job.currentCheckpointID }) else {
            throw Failure(description: "fixture-job-missing")
        }
        var session: ReconstructionJobSession?
        if !job.state.isTerminal {
            let active = try await builder(inference)(request.workspaceID, request.jobID, owner, store)
            session = active
            _ = await active.start(authority: .init(jobID: job.jobID, expectedJobState: job.state,
                checkpointID: checkpoint.checkpointID, checkpointRevision: checkpoint.revision,
                corpusManifestSHA256: checkpoint.corpusManifestSHA256, evidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256))
        }
        let state = try await owner.load(workspaceID: request.workspaceID)
        try ReconstructionCanonicalJSON.encode(state).write(to: root.appendingPathComponent("last-state.json"), options: .atomic)
        guard state.jobs.first(where: { $0.jobID == request.jobID })?.state == .completed,
              let synthesis = ReconstructionJobStatusSummary.make(jobID: request.jobID, state: state)?.finalSynthesis else {
            throw Failure(description: "fixture-job-not-completed")
        }
        let sources = try await owner.availableDurableAttachmentSources(workspaceID: request.workspaceID)
        await session?.retire()
        await ReconstructionSourceOriginalSessionRegistry.shared.remove(workspaceID: request.workspaceID, jobID: request.jobID)
        await original?.retire(); await broker.reset(); await owner.revoke()
        let database = try WorkspaceDatabase(path: path)
        let journals = try database.ownerReplayRecords(workspaceID: request.workspaceID)
        _ = try database.replaceWorkspaceState(workspaceID: rowID, workspaceName: "T27 restart fixture",
            snapshot: .init(binaries: [], analysisBySlot: [:]), selectedSidebarItemID: nil, selectedAddress: nil,
            selectedTool: .reconstruction, editorMode: .disassembly, isInspectorPresented: false, sidebarSearchText: "")
        guard let history = try database.ownerInferenceHistory(workspaceID: request.workspaceID, jobID: request.jobID),
              history.rounds.count == state.modelReceipts.filter({ $0.terminalState == .completed }).count,
              try database.ownerReplayRecords(workspaceID: request.workspaceID).isEmpty,
              try database.ownerExecutionBudget(jobID: request.jobID) == nil else {
            throw Failure(description: "fixture-terminal-history-retention-mismatch")
        }
        let components = try database.packageComponents(workspaceID: rowID, documentID: UUID(),
            inputCopyingDecision: .copyInputsIntoPackage, bookmarkResolutionDecision: .resolveStoredBookmarks, phase2ShellSession: nil)
        let package = root.appendingPathComponent("Completed.mscope")
        try MacScopeDocumentPackage.writePackage(components.manifest, attachmentsByBinaryID: components.attachmentsByBinaryID,
            reconstructionState: state, reconstructionAttachmentSources: sources, to: package)
        let reopened = try MacScopeDocumentPackage.openPackage(from: package)
        guard reopened.reconstructionState == (try state.pruningTerminalReplayRecordsForSave()),
              reopened.reconstructionState.replayRecords == nil, reopened.manifest.requiredReaderFeatures.isEmpty else {
            throw Failure(description: "fixture-save-reopen-mismatch")
        }
        let reopenedDatabase = try WorkspaceDatabase(path: root.appendingPathComponent("completed-package.sqlite").path)
        try reopenedDatabase.applySchema()
        _ = try reopenedDatabase.importPackage(from: package)
        guard try reopenedDatabase.ownerInferenceHistory(workspaceID: request.workspaceID, jobID: request.jobID) == nil else {
            throw Failure(description: "fixture-completed-package-carried-live-history")
        }
        let allCalls = try await calls.records()
        let replayedNativePromptFacts = try journals.filter { $0.replayCount > 0 && $0.identity.requestKind == "roundR2" }
            .reduce(0) { count, record in
                guard let bytes = record.freshReply?.originalRequestBytes else { return count }
                return count + (try JSONDecoder().decode(ReconstructionInferenceRoundRequestR2.self,
                    from: bytes).request.transientAnalysis?.facts.count ?? 0)
            }
        return .init(pid: getpid(), state: "completed", freshSourceCalls: allCalls.filter { $0.kind == "source" }.count,
            freshRoundCalls: allCalls.filter { $0.kind == "round" }.count,
            replayedReplies: journals.reduce(0) { $0 + $1.replayCount }, replayedNativePromptFacts: replayedNativePromptFacts,
            activePackageMigrated: activePackageMigrated,
            liveHistoryRoundCount: history.rounds.count,
            liveHistoryReplayedRoundCount: history.rounds.filter { $0.mode == .replayed }.count,
            completedPackageHasNoReplayProvenance: true,
            sourceRevisions: synthesis.revisionCount,
            evaluations: synthesis.evaluationCount, harnessPassed: synthesis.harnessPassed, packageReopened: true,
            activationProhibited: NSApplication.shared.activationPolicy() == .prohibited,
            quitIgnoredDuringExecution: ReconstructionResumeFaultInjection.shared.observedIgnoredQuit
                || FileManager.default.fileExists(atPath: root.appendingPathComponent("quit-ignored.json").path),
            quitAllowedWhenIdle: MacScopeHeadlessHostPolicy.terminationReply() == .terminateNow)
    }

    private static func makeOwner(path: String, root: URL, request: Request, isNew: Bool) throws -> (Int64, ReconstructionDatabaseOwner) {
        let database = try WorkspaceDatabase(path: path)
        try database.applySchema()
        let rowID: Int64
        if isNew {
            let workspace = try database.saveSnapshot(workspaceUUID: request.workspaceID, workspaceName: "T27 restart fixture",
                snapshot: .init(binaries: [], analysisBySlot: [:]), now: Date())
            guard let id = workspace.id else { throw Failure(description: "fixture-workspace-missing") }; rowID = id
        } else {
            guard let row = try database.workspaceRecord(workspaceUUID: request.workspaceID), let id = row.id else {
                throw Failure(description: "fixture-workspace-missing")
            }; rowID = id
        }
        return (rowID, ReconstructionDatabaseOwner(database: database, attachmentVaultRootURL: root.appendingPathComponent("vault")))
    }

    static func makeController() async throws -> Phase2LocalAIProviderController {
        let endpoint = try Phase2LocalProviderEndpoint(profileID: UUID(), generation: 1,
            endpointOrigin: "http://127.0.0.1:8000", requestTimeoutMilliseconds: 900_000,
            resourceTimeoutMilliseconds: 1_800_000, inferencePolicy: .init())
        let model = Phase2LocalModelDescriptor(type: .language, publisher: "T27 fixture", key: "t27-loopback",
            displayName: "T27 deterministic loopback", architecture: "transformer", quantization: .init(name: "Q4", bitsPerWeight: 4),
            sizeBytesOnDisk: 1, parameterCountDescription: "fixture", maximumContextLength: 32_768, format: .gguf,
            capabilities: .init(supportsVision: false, trainedForToolUse: false,
                reasoning: .init(allowedOptions: [.off], defaultOption: .off)), variants: ["q4"], providerSelectedVariant: "q4",
            loadedInstances: [.init(id: UUID().uuidString, configuration: .init(effectiveContextLength: 32_768))])
        let inventory = try Phase2LocalModelInventory(profileID: endpoint.profileID, generation: endpoint.generation, models: [model])
        let controller = Phase2LocalAIProviderController(endpoint: endpoint,
            discovery: ReconstructionResumeDiscovery(inventory: inventory), lifecycle: ReconstructionResumeUnusedLifecycle(),
            preferenceStore: InMemoryPhase2LocalAIProviderPreferenceStore())
        _ = try await controller.refresh()
        try controller.select(modelKey: model.key, maximumTokens: 1_024)
        return controller
    }
}

/// The fixture installs this process-local barrier explicitly. Product launches have no installed
/// observer, do no file I/O here and cannot stop on an ambient environment variable.
final class ReconstructionResumeFaultInjection: @unchecked Sendable {
    static let shared = ReconstructionResumeFaultInjection()
    private let lock = NSLock()
    private var configuration: (root: URL, point: String)?
    private var ignoredQuit = false
    var observedIgnoredQuit: Bool { lock.withLock { ignoredQuit } }
    func install(root: URL, point: String) { lock.withLock { configuration = (root, point) } }
    func hit(_ point: String) {
        guard let configuration = lock.withLock({ self.configuration }), configuration.point == point else { return }
        do {
            let data = try ReconstructionCanonicalJSON.encode(["point": point, "pid": String(getpid())])
            let path = configuration.root.appendingPathComponent("kill-arrived.json")
            try data.write(to: path, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: path); try handle.synchronize(); try handle.close()
            FileHandle.standardOutput.write(Data("T27_KILL_READY \(point) \(getpid())\n".utf8))
            // Parent owns this process, observes the durable arrival, and sends SIGKILL. No sleep
            // polling or self-reported cancellation is substituted for a real process death.
            Darwin.kill(getpid(), SIGSTOP)
        } catch {
            FileHandle.standardError.write(Data("T27_BARRIER_ERROR \(error)\n".utf8)); Darwin.exit(EX_IOERR)
        }
    }
    @MainActor func observeQuit() {
        guard let root = lock.withLock({ configuration?.root }) else { return }
        let ignored = MacScopeHeadlessHostPolicy.terminationReply() == .terminateCancel
        // Exercise the installed headless delegate through AppKit's real Quit dispatch. Reaching
        // the following write proves the active process survived it; ordinary UI is never driven.
        if ignored { NSApplication.shared.terminate(nil) }
        lock.withLock { ignoredQuit = ignoredQuit || ignored }
        if ignored, let bytes = try? ReconstructionCanonicalJSON.encode(["ignored": "true", "pid": String(getpid())]) {
            try? bytes.write(to: root.appendingPathComponent("quit-ignored.json"), options: .atomic)
        }
    }
    func committed(_ mutation: ReconstructionCheckpointMutation) {
        if mutation.successorCheckpoint.coordinatorState == .executingReads { hit("executingReads") }
        if mutation.successorCheckpoint.coordinatorState == .completed { hit("completedCheckpoint") }
        if mutation.evidence.contains(where: { $0.operationID == ReconstructionSourceRevisionEvidence.operationID }) { hit("sourceRevisionCommitted") }
        if mutation.evidence.contains(where: {
            $0.operationID == ReconstructionSourceEvaluationEvidence.operationID
                && (try? ReconstructionSourceEvaluationCodec.decodeAndValidateCanonical(payload: $0.payload).capturedOutcome.status) == .behaviorMismatch
        }) { hit("behaviorFailure") }
    }
}

private struct ReconstructionResumeDiscovery: Phase2LocalModelDiscovering {
    let inventory: Phase2LocalModelInventory
    func discoverModels(endpoint: Phase2LocalProviderEndpoint, requestID: UUID) async throws -> Phase2LocalModelDiscoveryOutcome { .success(inventory) }
    func cancel(requestID: UUID) async {}
}
private struct ReconstructionResumeUnusedLifecycle: Phase2LocalModelLifecycleControlling {
    func perform(command: Phase2LocalModelLifecycleCommand, endpoint: Phase2LocalProviderEndpoint,
                 acceptedInventory: Phase2LocalModelInventory) async throws -> Phase2LocalModelLifecycleOutcome {
        throw ReconstructionResumeHost.Failure(description: "fixture-must-not-load-model")
    }
    func cancel(effectID: UUID) async {}
}

private actor ReconstructionResumeCallJournal {
    struct Call: Codable, Sendable { let kind: String; let requestID: UUID; let parent: String? }
    let root: URL
    init(root: URL) { self.root = root }
    func records() throws -> [Call] {
        let file = root.appendingPathComponent("fresh-calls.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([Call].self, from: Data(contentsOf: file))
    }
    func append(kind: String, requestID: UUID, parent: String? = nil) throws -> Int {
        var calls = try records(); calls.append(.init(kind: kind, requestID: requestID, parent: parent))
        let file = root.appendingPathComponent("fresh-calls.json")
        try ReconstructionCanonicalJSON.encode(calls).write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file); try handle.synchronize(); try handle.close()
        return calls.filter { $0.kind == kind }.count
    }
}

private struct ReconstructionResumeScriptedProvider: ReconstructionInferenceProviding {
    let calls: ReconstructionResumeCallJournal
    func cancel(requestID: UUID) async {}
    func runSourceRevision(requestID: UUID, request: ReconstructionSourceRevisionRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void) async throws -> ReconstructionTerminalReceipt {
        _ = try await calls.append(kind: "source", requestID: requestID, parent: request.parentRevisionSHA256)
        let text = request.parentRevisionSHA256 == nil
            ? "typedef unsigned int uint32_t;\nuint32_t reconstructed(uint32_t value) { return value + 1U; }\n"
            : "typedef unsigned int uint32_t;\nuint32_t reconstructed(uint32_t value) { return value == 4294967295U ? value : value + 1U; }\n"
        try await emit(.init(requestID: requestID, sequence: 1, body: .sourceCandidate(.init(profileID: request.profileID,
            parentRevisionSHA256: request.parentRevisionSHA256, sourceText: text, evidenceIDs: Array(request.context.evidenceIDs.prefix(64))))))
        try await finish(requestID: requestID, emit: emit)
        return .init(requestID: requestID, jobID: request.jobID, checkpointRevision: request.checkpointRevision, roundID: request.roundID, status: .completed)
    }
    func runRound(requestID: UUID, request: ReconstructionInferenceRoundRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void) async throws -> ReconstructionTerminalReceipt {
        throw ReconstructionResumeHost.Failure(description: "fixture-R2-required")
    }
    func runRoundR2(requestID: UUID, request: ReconstructionInferenceRoundRequestR2,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void) async throws -> ReconstructionTerminalReceipt {
        _ = try await calls.append(kind: "round", requestID: requestID)
        try await emit(.init(requestID: requestID, sequence: 1, body: .roundCandidate(.init(jobID: request.request.jobID,
            checkpointRevision: request.request.checkpointRevision, roundID: request.request.roundID,
            selectedHandleIDs: [], disposition: .sufficientEvidence, unresolvedGaps: []))))
        try await finish(requestID: requestID, emit: emit)
        return .init(requestID: requestID, jobID: request.request.jobID, checkpointRevision: request.request.checkpointRevision,
            roundID: request.request.roundID, status: .completed)
    }
    func runFinalSynthesis(requestID: UUID, request: ReconstructionFinalSynthesisRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void) async throws -> ReconstructionTerminalReceipt {
        throw ReconstructionResumeHost.Failure(description: "fixture-R2-required")
    }
    func runFinalSynthesisR2(requestID: UUID, request: ReconstructionFinalSynthesisRequestR2,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void) async throws -> ReconstructionTerminalReceipt {
        _ = try await calls.append(kind: "final", requestID: requestID)
        try await emit(.init(requestID: requestID, sequence: 1, body: .finalCandidate(.init(kind: .synthesis,
            text: "The child repair matches the captured original on all 37 fixed harness inputs.",
            evidenceIDs: request.request.acceptedEvidenceIDs))))
        try await finish(requestID: requestID, emit: emit)
        return .init(requestID: requestID, jobID: request.request.jobID, checkpointRevision: request.request.checkpointRevision,
            roundID: nil, status: .completed)
    }
    private func finish(requestID: UUID, emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void) async throws {
        try await emit(.init(requestID: requestID, sequence: 2, body: .usage(.init(promptTokens: 1, completionTokens: 1, totalTokens: 2))))
        try await emit(.init(requestID: requestID, sequence: 3, body: .completed))
    }
}

private actor ReconstructionResumeSourceTransport: ShellBrokerXPCTransport {
    let inner: any ShellBrokerXPCTransport
    init(inner: any ShellBrokerXPCTransport) { self.inner = inner }
    func handshake() async throws -> Phase2ShellBrokerHandshake { try await inner.handshake() }
    func perform(_ request: Phase2ShellBrokerCommandRequest) async throws -> Phase2ShellBrokerCommandResponse { try await inner.perform(request) }
    func prepareBrokerProcessReceipt() async throws -> ShellBrokerXPCProcessReceipt { try await inner.prepareBrokerProcessReceipt() }
    func revalidateBrokerProcessReceipt(_ receipt: ShellBrokerXPCProcessReceipt) async -> Bool { await inner.revalidateBrokerProcessReceipt(receipt) }
    func reset() async { await inner.reset() }
    func executeSource(_ request: Phase2SourceExecutionRequest) async throws -> Phase2SourceExecutionResponse {
        let result = try await inner.executeSource(request)
        if request.sourceAuthority == .admittedRevision, request.operation == .compile,
           result.status == .completed, result.failure == nil { ReconstructionResumeFaultInjection.shared.hit("buildCompleted") }
        return result
    }
}
