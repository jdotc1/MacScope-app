import XCTest
import Combine
@testable import MacScope

/// Tier-3 DEBUGGER-DEPTH: expression evaluator + threads tab.
///
/// These cover the non-UI logic for the two "inspect the stopped process"
/// features, mirroring the register-write / memory-read authoring tests:
///
///  * `DebuggerExpressionRequest` validation (accept / reject control chars +
///    empty + over-length),
///  * `DebuggerThreadSelectionRequest` validation,
///  * the view model's `evaluate()` / `selectThread(_:)` gating to a paused-live
///    session, the right client call, and surfaced result,
///  * the `expression --` / `thread list` / `thread select` command strings,
///  * `thread list` parsing into `[DebuggerThread]`,
///  * `expression --` result parsing into `DebuggerExpressionResult`,
///  * the live LLDB command session issuing the expression / thread commands
///    through the persistent transport.
@MainActor
final class DebuggerExpressionThreadsTests: XCTestCase {

    // MARK: - Expression request validation

    func testExpressionRequestParseAcceptsAndTrims() {
        guard case .success(let request) = DebuggerExpressionRequest.parse("  x0 + 1  ") else {
            return XCTFail("A plain expression should parse.")
        }
        XCTAssertEqual(request, DebuggerExpressionRequest(expression: "x0 + 1"))
        XCTAssertEqual(request.displayName, "x0 + 1")
    }

    func testExpressionRequestParseRejectsEmpty() {
        if case .success = DebuggerExpressionRequest.parse("   ") {
            XCTFail("An empty expression should be rejected.")
        }
    }

    func testExpressionRequestParseRejectsControlCharacters() {
        // A newline would terminate the LLDB command line early and let the
        // remainder be interpreted as a separate command — the injection vector.
        if case .success = DebuggerExpressionRequest.parse("system(\"id\")\nprocess kill") {
            XCTFail("A newline-bearing expression should be rejected.")
        }
        if case .success = DebuggerExpressionRequest.parse("x0\u{0007}") {
            XCTFail("A control character should be rejected.")
        }
    }

    func testExpressionRequestParseRejectsOverLength() {
        let huge = String(repeating: "a", count: DebuggerExpressionRequest.maximumLength + 1)
        if case .success = DebuggerExpressionRequest.parse(huge) {
            XCTFail("An over-length expression should be rejected.")
        }
    }

    // MARK: - Thread selection request validation

    func testThreadSelectionRequestParseAcceptsPositiveIndex() {
        guard case .success(let request) = DebuggerThreadSelectionRequest.parse(index: 2) else {
            return XCTFail("A positive index should parse.")
        }
        XCTAssertEqual(request.index, 2)
    }

    func testThreadSelectionRequestParseRejectsNonPositiveIndex() {
        if case .success = DebuggerThreadSelectionRequest.parse(index: 0) {
            XCTFail("Index 0 should be rejected (LLDB thread indexes are 1-based).")
        }
        if case .success = DebuggerThreadSelectionRequest.parse(index: -1) {
            XCTFail("Negative index should be rejected.")
        }
    }

    // MARK: - Command strings

    func testExpressionCommandString() {
        let request = DebuggerExpressionRequest(expression: "x0 + 1")
        XCTAssertEqual(
            XcodeLLDBCommandLineAdapter.makeExpressionCommand(for: request),
            "expression -- x0 + 1"
        )
    }

    func testThreadSelectAndListCommandStrings() {
        let request = DebuggerThreadSelectionRequest(index: 3)
        XCTAssertEqual(
            XcodeLLDBCommandLineAdapter.makeThreadSelectCommand(for: request),
            "thread select 3"
        )
        XCTAssertEqual(XcodeLLDBCommandLineAdapter.liveThreadListCommand, "thread list")
    }

    func testControlActionTitlesForNewActions() {
        XCTAssertEqual(DebuggerControlAction.evaluateExpression.title, "Evaluate Expression")
        XCTAssertEqual(DebuggerControlAction.selectThread.title, "Select Thread")
    }

    // MARK: - thread list parsing

    func testParseThreadListRecoversIndexTIDNameSelectionAndStopReason() {
        let transcript = """
        Process 222 stopped
        * thread #1: tid = 0x1f3c, 0x0000000100003f80 echo`main + 8, queue = 'com.apple.main-thread', stop reason = breakpoint 1.1
          thread #2: tid = 0x1f40, 0x0000000180001000 libsystem`__workq, name = 'worker', stop reason = signal SIGSTOP
        """
        let threads = XcodeLLDBCommandLineAdapter.parseThreadList(from: transcript)
        XCTAssertEqual(threads.count, 2)

        XCTAssertEqual(threads[0].index, 1)
        XCTAssertEqual(threads[0].tid, 0x1f3c)
        XCTAssertTrue(threads[0].isSelected)
        // `thread list` does not print a `frame #N:` line, so the breakpoint
        // address is not recoverable from the thread line alone — the parser
        // reports the breakpoint stop without an address.
        XCTAssertEqual(threads[0].stopReason, .unknown("Breakpoint hit"))

        XCTAssertEqual(threads[1].index, 2)
        XCTAssertEqual(threads[1].tid, 0x1f40)
        XCTAssertFalse(threads[1].isSelected)
        XCTAssertEqual(threads[1].name, "worker")
        XCTAssertEqual(threads[1].stopReason, .signal("SIGSTOP"))
    }

    func testParseThreadListEmptyTranscriptYieldsNoThreads() {
        XCTAssertTrue(XcodeLLDBCommandLineAdapter.parseThreadList(from: "no threads here").isEmpty)
    }

    // MARK: - expression result parsing

    func testParseExpressionResultRecoversTypeAndValue() {
        let result = XcodeLLDBCommandLineAdapter.parseExpressionResult(from: "(int) $0 = 42")
        XCTAssertEqual(result, DebuggerExpressionResult(value: "42", type: "int"))
        XCTAssertEqual(result?.displayName, "(int) 42")
    }

    func testParseExpressionResultRecoversPointerValue() {
        let result = XcodeLLDBCommandLineAdapter.parseExpressionResult(
            from: #"(const char *) $1 = 0x0000000100003f80 "hello""#
        )
        XCTAssertEqual(result?.type, "const char *")
        XCTAssertEqual(result?.value, #"0x0000000100003f80 "hello""#)
    }

    func testParseExpressionResultFallsBackToBareValueLine() {
        let result = XcodeLLDBCommandLineAdapter.parseExpressionResult(from: "(lldb) expr\n42")
        XCTAssertEqual(result, DebuggerExpressionResult(value: "42", type: nil))
    }

    func testParseExpressionResultReturnsNilForNoValue() {
        XCTAssertNil(XcodeLLDBCommandLineAdapter.parseExpressionResult(from: "(lldb) \n   "))
    }

    // MARK: - View model: evaluate()

    func testViewModelEvaluateFormsClientCallInPausedLiveSession() async {
        let client = ExprThreadsRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertTrue(viewModel.canEvaluateExpression)
        XCTAssertTrue(viewModel.controlAvailability(for: .evaluateExpression).isEnabled)

        viewModel.expressionText = "x0 + 1"
        await viewModel.evaluate()

        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(client.evaluateCallCount, 1)
        XCTAssertEqual(client.lastExpression, DebuggerExpressionRequest(expression: "x0 + 1"))
        XCTAssertEqual(viewModel.expressionResult, DebuggerExpressionResult(value: "43", type: "int"))
    }

    func testViewModelEvaluateRejectsInvalidInputWithoutClientCall() async {
        let client = ExprThreadsRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        viewModel.expressionText = "x0\nprocess kill"
        await viewModel.evaluate()

        XCTAssertEqual(client.evaluateCallCount, 0)
        XCTAssertNil(viewModel.expressionResult)
        XCTAssertTrue(viewModel.lastError?.contains("control characters") ?? false)
    }

    func testViewModelEvaluateGatedOffWhenNotPausedLive() async {
        let runningSnapshot = DebuggerSessionSnapshot(
            processState: .running(processID: 222, executableName: "echo"),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Running.",
            backendState: .connected(processID: 222, adapterName: "ExprThreads Recording LLDB")
        )
        let client = ExprThreadsRecordingDebuggerClient(initialSnapshot: runningSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertFalse(viewModel.canEvaluateExpression)
        XCTAssertFalse(viewModel.controlAvailability(for: .evaluateExpression).isEnabled)

        viewModel.expressionText = "x0"
        await viewModel.evaluate()

        XCTAssertEqual(client.evaluateCallCount, 0)
        XCTAssertEqual(viewModel.lastError, "Expression evaluation requires a paused live debug process.")
    }

    func testViewModelEvaluatePreservedStateWhenBackendUnsupported() async {
        let client = ExprThreadsUnsupportedControlDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertFalse(viewModel.canEvaluateExpression)
        viewModel.expressionText = "x0"
        await viewModel.evaluate()

        XCTAssertEqual(client.evaluateCallCount, 0)
        XCTAssertTrue(viewModel.lastError?.hasPrefix("Expression evaluation unavailable:") ?? false)
    }

    // MARK: - View model: selectThread()

    func testViewModelSelectThreadFormsClientCallAndUpdatesActiveThread() async {
        let client = ExprThreadsRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertTrue(viewModel.canSelectThread)
        XCTAssertTrue(viewModel.controlAvailability(for: .selectThread).isEnabled)

        await viewModel.selectThread(2)

        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(client.selectThreadCallCount, 1)
        XCTAssertEqual(client.lastThreadSelection, DebuggerThreadSelectionRequest(index: 2))
        // The recording client marks thread #2 selected; the view model surfaces
        // the updated thread list.
        XCTAssertEqual(viewModel.threads.first(where: { $0.isSelected })?.index, 2)
    }

    /// Tier 2m P3: frame #4 selected on thread #2, then thread #1 selected. The new thread starts
    /// at its top frame; the previous thread's frame index must not carry over.
    func testViewModelSelectThreadResetsTheSelectedFrameToTheNewThreadsTopFrame() async {
        var snapshot = Self.pausedLiveSnapshot
        snapshot.frames = (0..<5).map {
            DebuggerFrameSummary(
                index: $0,
                address: 0x1000_0010 + UInt64($0) * 0x10,
                functionName: "f\($0)",
                moduleName: "echo",
                sourceLocation: nil
            )
        }
        let client = ExprThreadsRecordingDebuggerClient(initialSnapshot: snapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        await viewModel.selectFrame(4)
        XCTAssertEqual(viewModel.selectedFrameIndex, 4)

        await viewModel.selectThread(2)

        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(viewModel.threads.first(where: { $0.isSelected })?.index, 2)
        XCTAssertNil(viewModel.selectedFrameIndex)
    }

    func testViewModelSelectThreadRejectsNonPositiveWithoutClientCall() async {
        let client = ExprThreadsRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        await viewModel.selectThread(0)

        XCTAssertEqual(client.selectThreadCallCount, 0)
        XCTAssertTrue(viewModel.lastError?.contains("positive") ?? false)
    }

    func testViewModelSelectThreadGatedOffWhenNotPausedLive() async {
        let mismatched = DebuggerSessionSnapshot(
            processState: .paused(processID: 222, reason: .userRequested),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused.",
            backendState: .connected(processID: 999, adapterName: "ExprThreads Recording LLDB")
        )
        let client = ExprThreadsRecordingDebuggerClient(initialSnapshot: mismatched)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertFalse(viewModel.canSelectThread)
        await viewModel.selectThread(1)

        XCTAssertEqual(client.selectThreadCallCount, 0)
        XCTAssertEqual(viewModel.lastError, "Thread selection requires a paused live debug process.")
    }

    // MARK: - Live transport (expression + thread select through the session)

    func testLiveCommandSessionEvaluatesExpressionAndSelectsThreadThroughTransport() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let transport = ExprThreadsFakeLLDBCommandSessionTransport(responses: [
            // launch setup + launch + status + stopped-refresh (thread backtrace,
            // registers, stack memory)
            .empty,
            .empty,
            .launchStoppedAtEntry,
            .statusStopped,
            .backtrace,
            .registers,
            .stackMemory,
            // expression --
            .expressionResult,
            // thread select 2 + thread list + backtrace + registers
            .empty,
            .threadList,
            .backtrace,
            .registers
        ])
        let runner = ExprThreadsFakeDebuggerProcessRunner(result: .successfulProof)
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            lldbExecutablePath: lldbPath,
            processRunner: runner,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: "/tmp/MacScopeExprThreadsProof",
            liveSessionFactory: { transport }
        ))

        let launched = try await client.launch(DebuggerLaunchConfiguration(executablePath: "/bin/echo"))
        XCTAssertEqual(launched.processState, .paused(processID: 222, reason: .unknown("Stopped at entry")))

        let result = try await client.evaluateExpression(
            DebuggerExpressionRequest(expression: "x0 + 1"),
            from: launched
        )
        XCTAssertEqual(result, DebuggerExpressionResult(value: "43", type: "int"))

        let afterSelect = try await client.selectThread(
            DebuggerThreadSelectionRequest(index: 2),
            from: launched
        )
        XCTAssertEqual(afterSelect.statusMessage, "Selected thread #2.")
        XCTAssertEqual(
            afterSelect.lastCommandRun?.commandDisplay,
            "thread select 2; thread list; thread backtrace; \(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)"
        )

        XCTAssertEqual(transport.sentCommands, [
            "settings set use-color false",
            #"target create "/bin/echo""#,
            "process launch --stop-at-entry",
            "process status",
            "thread backtrace",
            "\(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)",
            "memory read --format x --size 1 --count 64 $sp",
            "expression -- x0 + 1",
            "thread select 2",
            "thread list",
            "thread backtrace",
            "\(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)"
        ])
        XCTAssertEqual(transport.stopCallCount, 0)
    }

    func testLiveCommandSessionRejectsExpressionWhenNotPaused() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let transport = ExprThreadsFakeLLDBCommandSessionTransport(responses: [])
        let runner = ExprThreadsFakeDebuggerProcessRunner(result: .successfulProof)
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            lldbExecutablePath: lldbPath,
            processRunner: runner,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: "/tmp/MacScopeExprThreadsProof",
            liveSessionFactory: { transport }
        ))

        let running = DebuggerSessionSnapshot(
            processState: .running(processID: 222, executableName: "echo"),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Running.",
            backendState: .connected(processID: 222, adapterName: "Xcode LLDB Live")
        )

        do {
            _ = try await client.evaluateExpression(
                DebuggerExpressionRequest(expression: "x0"),
                from: running
            )
            XCTFail("Expression evaluation should be rejected when not paused.")
        } catch let error as DebuggerClientError {
            XCTAssertEqual(error, .invalidState("Expression evaluation requires a paused live debug process."))
        }
        XCTAssertTrue(transport.sentCommands.isEmpty)
    }

    // MARK: - Shared fixtures

    func testWatchDefinitionsAreBoundedValidatedAndAtomicallyRestored() throws {
        let client = ExprThreadsRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let model = DebuggerPanelViewModel(client: client)
        let definitions = try (0..<16).map { try DebuggerWatchDefinition(expression: "x\($0)") }
        try model.replaceWatchDefinitions(definitions)
        model.addWatch(expression: "overflow")
        XCTAssertEqual(model.watchDefinitions, definitions)
        XCTAssertNotNil(model.watchAuthoringError)
        XCTAssertThrowsError(try model.replaceWatchDefinitions([definitions[0], definitions[0]]))
        XCTAssertEqual(model.watchDefinitions, definitions)
        XCTAssertThrowsError(try DebuggerWatchDefinition(expression: String(repeating: "é", count: 513)))
        XCTAssertThrowsError(try DebuggerWatchDefinition(expression: "x0\nprocess kill"))
        let restored = try JSONDecoder().decode([DebuggerWatchDefinition].self,
            from: JSONEncoder().encode(definitions))
        XCTAssertEqual(restored, definitions)
        XCTAssertEqual(client.evaluateCallCount, 0, "Adding/restoring definitions never executes expressions.")
    }

    func testWatchPersistenceRestoreDoesNotEchoAndRejectedAuthoringIsAtomic() async throws {
        let client = ExprThreadsRecordingDebuggerClient(initialSnapshot: try Self.watchSnapshot())
        let model = DebuggerPanelViewModel(client: client)
        let initial = try DebuggerWatchDefinition(expression: "x0")
        var commits = 0
        try model.configureWatchPersistence(initialDefinitions: [initial]) { _ in
            commits += 1
            throw WorkspaceDocumentSessionError.closed
        }
        XCTAssertTrue(model.watchesAreSaved)
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(client.evaluateCallCount, 0)
        await model.evaluateWatches()
        let values = model.watchEvaluations
        model.watchExpressionText = "x1"
        model.addWatch(expression: model.watchExpressionText)
        XCTAssertEqual(model.watchDefinitions, [initial])
        XCTAssertEqual(model.watchEvaluations, values)
        XCTAssertEqual(model.watchExpressionText, "x1")
        XCTAssertNotNil(model.watchAuthoringError)
        model.removeWatch(id: initial.id)
        XCTAssertEqual(model.watchDefinitions, [initial])
        XCTAssertEqual(model.watchEvaluations, values)
        XCTAssertEqual(commits, 2)
        XCTAssertThrowsError(try model.configureWatchPersistence(initialDefinitions: []) { _ in })
    }

    func testWorkspaceWatchFactoryRestoresAndCommitsWithoutChangingLogicalIdentity() throws {
        let store = WorkspaceStore(workspaceName: "Watch glue", snapshot: AnalysisEngine.previewSnapshot(),
                                   engine: AnalysisEngine(), autosaveScheduler: nil)
        let owner = try XCTUnwrap(store.captureSavedWatchOwner())
        let definition = try WorkspaceSavedWatchDefinition(id: UUID(), expression: "x0")
        try store.replaceSavedWatchDefinitions([definition], owner: owner)
        let generation = store.mutationGeneration
        let client = ExprThreadsRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let model = DebuggerPanelViewModel.makeWorkspaceModel(client: client, store: store)
        XCTAssertEqual(store.mutationGeneration, generation, "Restoring must not dirty the document.")
        XCTAssertEqual(model.watchDefinitions.map(\.id), [definition.id])
        XCTAssertTrue(model.watchesAreSaved)
        XCTAssertEqual(client.evaluateCallCount, 0)
        model.addWatch(expression: "x1")
        XCTAssertEqual(store.savedWatchCatalog.definitions.map(\.expression), ["x0", "x1"])
        XCTAssertEqual(model.watchDefinitions.map(\.expression), ["x0", "x1"])
        XCTAssertNotEqual(store.mutationGeneration, generation)
        XCTAssertEqual(store.captureSavedWatchOwner(), owner, "Authoring must not fork document/workspace ownership.")
        XCTAssertTrue(store.hasUnsavedChanges)
        model.removeWatch(id: definition.id)
        XCTAssertEqual(store.savedWatchCatalog.definitions.map(\.expression), ["x1"])
        XCTAssertEqual(model.watchDefinitions.map(\.expression), ["x1"])
    }

    func testWorkspaceWatchFactoryRejectsRetiredAndChangedOwnersWithoutLocalOrStoreMutation() throws {
        for retirement in [false, true] {
            let store = WorkspaceStore(workspaceName: "Watch owner", snapshot: AnalysisEngine.previewSnapshot(),
                                       engine: AnalysisEngine(), autosaveScheduler: nil)
            let client = ExprThreadsRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
            let model = DebuggerPanelViewModel.makeWorkspaceModel(client: client, store: store)
            model.addWatch(expression: "x0")
            if retirement { store.retireDocumentSessionWriter() }
            else { _ = store.forkWorkspaceIdentity() }
            let catalog = store.savedWatchCatalog
            let definitions = model.watchDefinitions
            let generation = store.mutationGeneration
            model.addWatch(expression: "x1")
            model.removeWatch(id: definitions[0].id)
            XCTAssertEqual(store.savedWatchCatalog, catalog)
            XCTAssertEqual(store.mutationGeneration, generation)
            XCTAssertEqual(model.watchDefinitions, definitions)
            XCTAssertNotNil(model.watchAuthoringError)
            XCTAssertEqual(client.evaluateCallCount, 0)
        }
    }

    func testEditorInstallationRestoresFreshWatchesOnlyAfterPriorDebuggerDrains() async throws {
        for sameLogicalIDs in [false, true] {
            let store = WorkspaceStore(workspaceName: "Editor installation", snapshot: AnalysisEngine.previewSnapshot(),
                                       engine: AnalysisEngine(), autosaveScheduler: nil)
            let database = try WorkspaceDatabase.inMemory()
            try database.applySchema()
            var saved = try store.saveWorkspace(to: database)
            let oldClient = ExprThreadsRecordingDebuggerClient(initialSnapshot: try Self.watchSnapshot())
            let oldModel = DebuggerPanelViewModel.makeWorkspaceModel(client: oldClient, store: store)
            oldModel.addWatch(expression: "old")
            let oldOwner = try XCTUnwrap(oldModel.savedWatchOwner)
            XCTAssertTrue(store.installPhase2DebuggerProposalExecutor(oldModel, owner: oldOwner))
            let oldIdentity = EditorSceneIdentity(store: store)
            let shutdownStarted = expectation(description: "old debugger shutdown")
            var shutdownContinuation: CheckedContinuation<Void, Never>?
            oldClient.shutdownHandler = {
                await withCheckedContinuation { continuation in
                    shutdownContinuation = continuation
                    shutdownStarted.fulfill()
                }
            }
            let freshDefinition = try WorkspaceSavedWatchDefinition(id: UUID(), expression: "fresh")
            if sameLogicalIDs {
                saved.snapshot.savedWatchCatalog = try WorkspaceSavedWatchCatalog(definitions: [freshDefinition])
                store.restoreWorkspace(saved)
            } else {
                _ = store.forkWorkspaceIdentity()
                try store.replaceSavedWatchDefinitions([freshDefinition], owner: XCTUnwrap(store.captureSavedWatchOwner()))
            }
            XCTAssertNotEqual(EditorSceneIdentity(store: store), oldIdentity)
            if sameLogicalIDs {
                XCTAssertEqual(store.workspaceID, oldIdentity.workspaceID)
                XCTAssertEqual(store.documentID, oldIdentity.documentID)
            }
            await fulfillment(of: [shutdownStarted], timeout: 2)
            let newClient = ExprThreadsRecordingDebuggerClient(initialSnapshot: try Self.watchSnapshot())
            let freshModel = DebuggerPanelViewModel.makeWorkspaceModel(client: newClient, store: store)
            let freshOwner = try XCTUnwrap(freshModel.savedWatchOwner)
            XCTAssertTrue(freshModel.workspaceAdmissionPending)
            XCTAssertEqual(freshModel.watchDefinitions.map(\.id), [freshDefinition.id])
            XCTAssertTrue(freshModel.watchEvaluations.isEmpty)
            XCTAssertFalse(freshModel.controlAvailability(for: .evaluateExpression).isEnabled)
            freshModel.expressionText = "x0"
            await freshModel.evaluate()
            await freshModel.evaluateWatches()
            XCTAssertEqual(newClient.evaluateCallCount, 0)
            XCTAssertFalse(store.installPhase2DebuggerProposalExecutor(oldModel, owner: oldOwner))
            XCTAssertTrue(store.installPhase2DebuggerProposalExecutor(freshModel, owner: freshOwner))
            oldModel.addWatch(expression: "stale")
            XCTAssertEqual(store.savedWatchCatalog.definitions, [freshDefinition])
            let admitted = expectation(description: "fresh debugger admitted")
            let observation = freshModel.$workspaceAdmissionPending.dropFirst().filter { !$0 }.sink { _ in admitted.fulfill() }
            shutdownContinuation?.resume()
            await fulfillment(of: [admitted], timeout: 2)
            withExtendedLifetime(observation) {}
            XCTAssertFalse(freshModel.workspaceAdmissionPending)
            await freshModel.evaluateWatches()
            XCTAssertEqual(newClient.evaluateCallCount, 1)
            XCTAssertEqual(freshModel.watchEvaluations.count, 1)
            XCTAssertEqual(oldClient.shutdownCallCount, 1)
        }
    }

    func testPendingDebuggerAdmissionCannotReopenAfterAnotherDocumentReplacement() async throws {
        let store = WorkspaceStore(workspaceName: "Pending owner", snapshot: AnalysisEngine.previewSnapshot(),
                                   engine: AnalysisEngine(), autosaveScheduler: nil)
        let model = DebuggerPanelViewModel.makeWorkspaceModel(
            client: ExprThreadsRecordingDebuggerClient(initialSnapshot: try Self.watchSnapshot()), store: store)
        let owner = try XCTUnwrap(model.savedWatchOwner)
        let entered = expectation(description: "admission drain entered")
        var continuation: CheckedContinuation<Void, Never>?
        let drain = Task { @MainActor in
            await withCheckedContinuation { pending in continuation = pending; entered.fulfill() }
        }
        model.deferWorkspaceAdmission(until: drain) { store.isCurrentSavedWatchOwner(owner) }
        XCTAssertTrue(store.installPhase2DebuggerProposalExecutor(model, owner: owner))
        await fulfillment(of: [entered], timeout: 2)
        _ = store.forkWorkspaceIdentity()
        continuation?.resume()
        await drain.value
        await store.awaitDebuggerPresentationRetirement()
        XCTAssertFalse(model.controlAvailability(for: .evaluateExpression).isEnabled)
        XCTAssertFalse(store.isCurrentSavedWatchOwner(owner))
    }

    func testCompetingFactoryCannotExecuteBeforeItsRejectedEditorAppearance() async throws {
        let store = WorkspaceStore(workspaceName: "One editor owner", snapshot: AnalysisEngine.previewSnapshot(),
                                   engine: AnalysisEngine(), autosaveScheduler: nil)
        let first = DebuggerPanelViewModel.makeWorkspaceModel(
            client: ExprThreadsRecordingDebuggerClient(initialSnapshot: try Self.watchSnapshot()), store: store)
        let firstOwner = try XCTUnwrap(first.savedWatchOwner)
        XCTAssertTrue(store.installPhase2DebuggerProposalExecutor(first, owner: firstOwner))
        let rejectedClient = ExprThreadsRecordingDebuggerClient(initialSnapshot: try Self.watchSnapshot())
        let rejected = DebuggerPanelViewModel.makeWorkspaceModel(client: rejectedClient, store: store)
        XCTAssertFalse(rejected.controlAvailability(for: .evaluateExpression).isEnabled)
        rejected.expressionText = "x0"
        await rejected.evaluate()
        await rejected.evaluateWatches()
        XCTAssertEqual(rejectedClient.evaluateCallCount, 0)
        XCTAssertTrue(store.installPhase2DebuggerProposalExecutor(first, owner: firstOwner))
        await store.awaitDebuggerPresentationRetirement()
        XCTAssertEqual(rejectedClient.shutdownCallCount, 1)
    }

    func testWatchesRequireExactAuthorityAndEvaluateSequentiallyWithoutScalarMutation() async throws {
        let client = ExprThreadsRecordingDebuggerClient(initialSnapshot: try Self.watchSnapshot())
        let model = DebuggerPanelViewModel(client: client)
        model.addWatch(expression: "x0")
        model.addWatch(expression: "x1")
        let coordinate = try XCTUnwrap(model.currentInspectionCoordinate)
        XCTAssertEqual(client.evaluateCallCount, 0)
        await model.evaluateWatches()
        XCTAssertEqual(client.evaluateCallCount, 2)
        XCTAssertEqual(model.watchEvaluations.count, 2)
        XCTAssertTrue(model.watchEvaluations.values.allSatisfy { $0.coordinate == coordinate && $0.value == "43" })
        XCTAssertNil(model.expressionResult)
        XCTAssertNil(model.watchEvaluationRequestID)
        // A real control request invalidates values before any eventual snapshot replacement.
        await model.selectThread(2)
        XCTAssertTrue(model.watchEvaluations.isEmpty)
        XCTAssertEqual(model.watchDefinitions.count, 2)
        let legacy = DebuggerPanelViewModel(client: ExprThreadsRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot))
        legacy.addWatch(expression: "x0")
        XCTAssertFalse(legacy.canEvaluateWatches)
        await legacy.evaluateWatches()
        XCTAssertTrue(legacy.watchEvaluations.isEmpty)
    }

    func testWatchFailureClearsEarlierValuesAndStopsTheBatch() async throws {
        let client = ExprThreadsRecordingDebuggerClient(initialSnapshot: try Self.watchSnapshot())
        client.expressionHandler = { request, _ in
            if request.expression == "bad" { throw DebuggerClientError.backendFailure("watch failed") }
            return DebuggerExpressionResult(value: "7", type: "int")
        }
        let model = DebuggerPanelViewModel(client: client)
        for expression in ["good", "bad", "never"] { model.addWatch(expression: expression) }
        await model.evaluateWatches()
        XCTAssertEqual(client.evaluateCallCount, 2)
        XCTAssertEqual(model.watchEvaluations.count, 1)
        XCTAssertTrue(model.watchEvaluations.values.allSatisfy { $0.value == nil && $0.error != nil })
        XCTAssertEqual(model.watchDefinitions.count, 3)
    }

    func testWatchRefreshedSameStopPublishesButChangedStopRevokesValues() async throws {
        for changeStop in [false, true] {
            let snapshot = try Self.watchSnapshot()
            let client = ExprThreadsRecordingDebuggerClient(initialSnapshot: snapshot)
            client.expressionHandler = { _, current in
                var refreshed = current
                if changeStop, let stop = current.transportStopCoordinate {
                    refreshed.transportStopCoordinate = DebuggerStopCoordinate(
                        session: stop.session, stopRevision: DebuggerStopRevision(rawValue: 2)
                    )
                    refreshed.transportEventSequence = DebuggerEventSequence(rawValue: 2)
                }
                return DebuggerExpressionResult(value: "43", type: "int", refreshedSnapshot: refreshed)
            }
            let model = DebuggerPanelViewModel(client: client)
            model.addWatch(expression: "x0")
            model.addWatch(expression: "x1")
            await model.evaluateWatches()
            XCTAssertEqual(client.evaluateCallCount, changeStop ? 1 : 2)
            XCTAssertEqual(model.watchEvaluations.count, changeStop ? 0 : 2)
            XCTAssertNil(model.watchEvaluationRequestID)
        }
    }

    func testHeldWatchSuccessAndFailureCannotReviveRetiredOrReplacedDefinitions() async throws {
        for retirement in [false, true] {
            for failure in [false, true] {
                let started = expectation(description: "watch started")
                var continuation: CheckedContinuation<DebuggerExpressionResult, any Error>?
                let client = ExprThreadsRecordingDebuggerClient(initialSnapshot: try Self.watchSnapshot())
                client.expressionHandler = { _, _ in
                    try await withCheckedThrowingContinuation { pending in
                        continuation = pending
                        started.fulfill()
                    }
                }
                let model = DebuggerPanelViewModel(client: client)
                model.addWatch(expression: "first")
                model.addWatch(expression: "never")
                let task = Task { await model.evaluateWatches() }
                await fulfillment(of: [started], timeout: 2)
                if retirement { _ = model.beginWorkspaceRetirement() }
                else { try model.replaceWatchDefinitions([DebuggerWatchDefinition(expression: "replacement")]) }
                if failure { continuation?.resume(throwing: DebuggerClientError.backendFailure("late failure")) }
                else { continuation?.resume(returning: DebuggerExpressionResult(value: "late", type: nil)) }
                await task.value
                XCTAssertEqual(client.evaluateCallCount, 1)
                XCTAssertTrue(model.watchEvaluations.isEmpty)
                XCTAssertNil(model.watchEvaluationRequestID)
                XCTAssertNil(model.lastError)
            }
        }
    }

    private static func watchSnapshot() throws -> DebuggerSessionSnapshot {
        var snapshot = pausedLiveSnapshot
        let identity = try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: 222,
            startTime: XCTUnwrap(DebuggerProcessStartIdentity(seconds: 1_700_000_000, microseconds: 42)),
            realUserID: 501, effectiveUserID: 501,
            canonicalExecutablePath: "/bin/echo", executableDeviceID: 10,
            executableFileID: 1222, executableByteCount: 4096,
            executableSHA256: String(repeating: "a", count: 64), architecture: .arm64,
            machOUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"), codeIdentity: nil
        ))
        let stop = DebuggerStopCoordinate(
            session: DebuggerSessionCoordinate(epoch: DebuggerSessionEpoch(rawValue: UUID()),
                lifecycleRevision: DebuggerLifecycleRevision(rawValue: 1)),
            stopRevision: DebuggerStopRevision(rawValue: 1)
        )
        snapshot.transportSessionCoordinate = stop.session
        snapshot.transportStopCoordinate = stop
        snapshot.transportTargetAuthority = try DebuggerSessionTargetAuthority(origin: .attached(identity))
        snapshot.transportTargetDisposition = .stopped(processID: 222)
        snapshot.transportEventSequence = DebuggerEventSequence(rawValue: 1)
        snapshot.frames = [DebuggerFrameSummary(index: 0, address: 0x1000_0010,
            functionName: "main", moduleName: "echo", sourceLocation: nil)]
        return snapshot
    }

    private static var pausedLiveSnapshot: DebuggerSessionSnapshot {
        DebuggerSessionSnapshot(
            processState: .paused(processID: 222, reason: .breakpoint(address: 0x1000_0010)),
            breakpoints: [DebuggerBreakpoint(address: 0x1000_0010)],
            threads: [
                DebuggerThreadSummary(
                    index: 1,
                    queueName: "com.apple.main-thread",
                    stopReason: .breakpoint(address: 0x1000_0010),
                    isSelected: true,
                    topFrameAddress: 0x1000_0010,
                    topFrameFunctionName: "main"
                ),
                DebuggerThreadSummary(
                    index: 2,
                    queueName: nil,
                    stopReason: nil,
                    isSelected: false,
                    topFrameAddress: 0x1800_0000,
                    topFrameFunctionName: "worker"
                )
            ],
            frames: [],
            registers: [DebuggerRegisterSummary(name: "x0", value: "0x000000000000002a", role: nil)],
            memoryRegions: [],
            statusMessage: "Paused at breakpoint.",
            backendState: .connected(processID: 222, adapterName: "ExprThreads Recording LLDB")
        )
    }
}

// MARK: - Self-contained test doubles

@MainActor
private final class ExprThreadsRecordingDebuggerClient: DebuggerClient {
    var shutdownHandler: (() async -> Void)?
    private(set) var shutdownCallCount = 0
    func shutdown() async {
        shutdownCallCount += 1
        await shutdownHandler?()
    }
    var expressionHandler: ((DebuggerExpressionRequest, DebuggerSessionSnapshot) async throws -> DebuggerExpressionResult)?
    private let initialSnapshot: DebuggerSessionSnapshot
    private(set) var evaluateCallCount = 0
    private(set) var selectThreadCallCount = 0
    private(set) var lastExpression: DebuggerExpressionRequest?
    private(set) var lastThreadSelection: DebuggerThreadSelectionRequest?

    init(initialSnapshot: DebuggerSessionSnapshot) {
        self.initialSnapshot = initialSnapshot
    }

    let capabilities = DebuggerCapabilityReport(
        backendName: "ExprThreads Recording LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: false,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: []
    )

    func makeInitialSnapshot() -> DebuggerSessionSnapshot { initialSnapshot }
    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot { initialSnapshot }
    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func writeRegister(_ request: DebuggerRegisterWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func readMemory(_ request: DebuggerMemoryReadRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }

    func evaluateExpression(_ request: DebuggerExpressionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerExpressionResult {
        evaluateCallCount += 1
        lastExpression = request
        if let expressionHandler { return try await expressionHandler(request, snapshot) }
        return DebuggerExpressionResult(value: "43", type: "int")
    }

    func selectThread(_ request: DebuggerThreadSelectionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        selectThreadCallCount += 1
        lastThreadSelection = request
        var copy = snapshot
        copy.threads = copy.threads.map { thread in
            var updated = thread
            updated.isSelected = thread.index == request.index
            return updated
        }
        copy.statusMessage = "Selected thread #\(request.index)."
        return copy
    }

    func selectFrame(_ request: DebuggerFrameSelectionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }

    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
}

@MainActor
private final class ExprThreadsUnsupportedControlDebuggerClient: DebuggerClient {
    private let initialSnapshot: DebuggerSessionSnapshot
    private(set) var evaluateCallCount = 0
    private(set) var selectThreadCallCount = 0

    init(initialSnapshot: DebuggerSessionSnapshot) {
        self.initialSnapshot = initialSnapshot
    }

    let capabilities = DebuggerCapabilityReport(
        backendName: "ExprThreads Batch LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: false,
        canControlExecution: false,
        limitations: ["Execution control disabled in this batch-only test client."],
        entitlementNotes: []
    )

    func makeInitialSnapshot() -> DebuggerSessionSnapshot { initialSnapshot }
    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot { initialSnapshot }
    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func writeRegister(_ request: DebuggerRegisterWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func readMemory(_ request: DebuggerMemoryReadRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }

    func evaluateExpression(_ request: DebuggerExpressionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerExpressionResult {
        evaluateCallCount += 1
        return DebuggerExpressionResult(value: "0", type: nil)
    }

    func selectThread(_ request: DebuggerThreadSelectionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        selectThreadCallCount += 1
        return snapshot
    }

    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
}

private final class ExprThreadsFakeDebuggerProcessRunner: DebuggerProcessRunning {
    private let result: DebuggerSubprocessResult
    private(set) var commands: [DebuggerExternalCommand] = []

    init(result: DebuggerSubprocessResult) {
        self.result = result
    }

    func run(_ command: DebuggerExternalCommand) throws -> DebuggerSubprocessResult {
        commands.append(command)
        return result
    }
}

private final class ExprThreadsFakeLLDBCommandSessionTransport: DebuggerLLDBCommandSessionTransport {
    private var responses: [DebuggerLLDBCommandResponse]
    private(set) var startCommands: [DebuggerExternalCommand] = []
    private(set) var sentCommands: [String] = []
    private(set) var stopCallCount = 0

    init(responses: [DebuggerLLDBCommandResponse]) {
        self.responses = responses
    }

    func start(_ command: DebuggerExternalCommand) throws {
        startCommands.append(command)
    }

    func send(_ command: String, timeoutSeconds: TimeInterval) throws -> DebuggerLLDBCommandResponse {
        sentCommands.append(command)
        guard !responses.isEmpty else {
            throw DebuggerLLDBCommandSessionError.writeFailed("ExprThreads fake transport has no queued response.")
        }
        var response = responses.removeFirst()
        response.command = command
        return response
    }

    func stop() {
        stopCallCount += 1
    }
}

private extension DebuggerLLDBCommandResponse {
    static var empty: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(command: "", standardOutput: "")
    }

    static var launchStoppedAtEntry: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "process launch --stop-at-entry",
            standardOutput: """
            Process 222 launched: '/bin/echo' (arm64e)
            Process 222 stopped
                frame #0: 0x0000000100000000 dyld`_dyld_start
            """
        )
    }

    static var statusStopped: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "process status",
            standardOutput: "Process 222 stopped"
        )
    }

    static var backtrace: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "thread backtrace",
            standardOutput: """
            * thread #1, queue = 'com.apple.main-thread'
              * frame #0: 0x00000001000003f8 echo`main + 8 at main.swift:12:5
            """
        )
    }

    static var registers: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "\(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)",
            standardOutput: """
                  pc = 0x00000001000003f8 echo`main + 8
                  sp = 0x000000016fdff200
                  fp = 0x000000016fdff220
                  lr = 0x0000000180001000 dyld`start + 604
                  x0 = 0x000000000000002a
            """
        )
    }

    static var stackMemory: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "memory read --format x --size 1 --count 64 $sp",
            standardOutput: """
            0x000000016fdff200: 0x01 0x00 0x00 0x00 0x00 0x00 0x00 0x00
            """
        )
    }

    static var expressionResult: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "expression -- x0 + 1",
            standardOutput: "(int) $0 = 43"
        )
    }

    static var threadList: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "thread list",
            standardOutput: """
            Process 222 stopped
              thread #1: tid = 0x1f3c, 0x00000001000003f8 echo`main + 8, queue = 'com.apple.main-thread'
            * thread #2: tid = 0x1f40, 0x0000000180001000 libsystem`__workq, name = 'worker'
            """
        )
    }
}

private extension DebuggerSubprocessResult {
    static var successfulProof: DebuggerSubprocessResult {
        DebuggerSubprocessResult(
            terminationStatus: 0,
            standardOutput: """
            (lldb) version
            lldb-2103.0.23.6
            (lldb) platform status
              Platform: host
                Triple: arm64-apple-macosx
            (lldb) settings show target.default-arch
            target.default-arch (arch) =
            """,
            standardError: "",
            timedOut: false
        )
    }
}
