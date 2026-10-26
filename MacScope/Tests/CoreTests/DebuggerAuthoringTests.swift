import XCTest
@testable import MacScope

/// Coverage for the Tier-2 debugger authoring surfaces, mirroring the
/// `DebuggerStepIntoOutTests` style:
///
///  * conditional-breakpoint editing round-trips an author's condition +
///    ignore-count into local `session.breakpoints` (preserving address / enabled /
///    hit-count) without treating static workspace addresses as runtime addresses,
///  * register-write is gated to a paused live session and forms the right
///    `DebuggerRegisterWriteRequest` client call,
///  * memory-address parsing accepts/rejects inputs and the read action gates on
///    the paused live-process state,
///  * the live LLDB command session issues `register write` / `memory read`
///    through the transport.
///
/// Fixtures are self-contained so this file never collides with the shared test
/// doubles in other debugger test files.
@MainActor
final class DebuggerAuthoringTests: XCTestCase {
    func testRepeatedDocumentInstallationsRetireEachDebuggerAndRejectStaleExecutor() async throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let firstClient = AuthoringRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let first = DebuggerPanelViewModel(client: firstClient)
        let firstOwner = try XCTUnwrap(store.captureSavedWatchOwner())
        XCTAssertTrue(store.installPhase2DebuggerProposalExecutor(first, owner: firstOwner))
        XCTAssertTrue(store.installPhase2DebuggerProposalExecutor(first, owner: firstOwner))
        let duplicateClient = AuthoringRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let duplicate = DebuggerPanelViewModel(client: duplicateClient)
        XCTAssertFalse(store.installPhase2DebuggerProposalExecutor(duplicate, owner: firstOwner))
        await store.debuggerAdmissionDrain(for: firstOwner)?.value
        XCTAssertEqual(duplicateClient.shutdownCallCount, 1)
        XCTAssertEqual(firstClient.shutdownCallCount, 0, "Rejecting a duplicate must preserve the admitted model.")
        _ = store.forkWorkspaceIdentity()
        let secondOwner = try XCTUnwrap(store.captureSavedWatchOwner())
        let secondClient = AuthoringRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let second = DebuggerPanelViewModel(client: secondClient)
        await store.debuggerAdmissionDrain(for: secondOwner)?.value
        XCTAssertEqual(firstClient.shutdownCallCount, 1)
        XCTAssertTrue(store.installPhase2DebuggerProposalExecutor(second, owner: secondOwner))
        XCTAssertFalse(store.installPhase2DebuggerProposalExecutor(first, owner: firstOwner))
        _ = store.forkWorkspaceIdentity()
        await store.awaitDebuggerPresentationRetirement()
        XCTAssertEqual(firstClient.shutdownCallCount, 1)
        XCTAssertEqual(secondClient.shutdownCallCount, 1)
    }
    func testRetirementDuringObservationCadenceDoesNotDispatchPoll() async {
        let client = AuthoringRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        var running = Self.pausedLiveSnapshot
        running.processState = .running(processID: 222, executableName: "fixture")
        client.continueResult = running
        let model = DebuggerPanelViewModel(client: client)
        let sleep = RetirementSuspension()
        model.processObservationSleep = { _ in await sleep.suspend() }
        let operation = Task { await model.continueExecution() }
        await sleep.waitUntilEntered()
        await model.beginWorkspaceRetirement().value
        sleep.resume()
        await operation.value
        XCTAssertEqual(client.pollCallCount, 0)
        XCTAssertNil(model.lastError)
    }

    func testHeldPollFailureCannotPublishAfterRetirement() async {
        let client = AuthoringRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        var running = Self.pausedLiveSnapshot
        running.processState = .running(processID: 222, executableName: "fixture")
        client.continueResult = running
        let poll = RetirementSuspension()
        client.pollHandler = { _ in
            await poll.suspend()
            throw DebuggerClientError.backendFailure("late retired poll")
        }
        let model = DebuggerPanelViewModel(client: client)
        model.processObservationSleep = { _ in }
        let operation = Task { await model.continueExecution() }
        await poll.waitUntilEntered()
        let acceptedSession = model.session
        await model.beginWorkspaceRetirement().value
        poll.resume()
        await operation.value
        XCTAssertEqual(client.pollCallCount, 1)
        XCTAssertEqual(model.session, acceptedSession)
        XCTAssertNil(model.lastError)
    }
    func testDocumentCloseRetiresDebuggerExactlyOnceWhileEditorOwnerIsRetained() async {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let client = AuthoringRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let model = DebuggerPanelViewModel(client: client)
        store.installPhase2DebuggerProposalExecutor(model, owner: store.captureSavedWatchOwner()!)
        let reservations = DebuggerRetirementTestReservations()
        let session = WorkspaceDocumentSession(sessionID: .init(rawValue: UUID()),
            windowID: .fresh(), source: store, io: WorkspaceDocumentIO(), reservations: reservations)
        store.updateLiveProgramCounterTarget(ImageAddress(slot: .primary, address: 0x1_0000_0000))
        session.close()
        session.close()
        await store.awaitDebuggerPresentationRetirement()
        await model.beginWorkspaceRetirement().value
        XCTAssertEqual(client.shutdownCallCount, 1)
        XCTAssertNil(store.liveProgramCounterTarget)
        await model.continueExecution()
        XCTAssertEqual(client.continueCallCount, 0)
        let retiredPresentation = model.session
        await model.stepOver()
        await model.stepInto()
        await model.stepOut()
        await model.pause()
        await model.detach()
        await model.terminate()
        await model.runToCursor(to: ImageAddress(slot: .primary, address: 0x1_0000_0000))
        await model.refreshSnapshot()
        XCTAssertEqual(client.stepOverCallCount, 0)
        XCTAssertEqual(client.pauseCallCount, 0)
        XCTAssertEqual(client.terminateCallCount, 0)
        XCTAssertEqual(client.runToCursorCallCount, 0)
        XCTAssertEqual(model.session, retiredPresentation)
        XCTAssertNil(model.lastError)
        withExtendedLifetime(model) {}
        withExtendedLifetime(reservations) {}
    }

    private func runToCursorRequest(
        runtimeAddress: UInt64,
        observedStopID: UInt32 = 9
    ) throws -> DebuggerRunToCursorRequest {
        let session = DebuggerSessionCoordinate(
            epoch: DebuggerSessionEpoch(
                rawValue: UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
            ),
            lifecycleRevision: .init(rawValue: 2)
        )
        let stop = DebuggerStopCoordinate(
            session: session,
            stopRevision: .init(rawValue: 3)
        )
        let inventoryRevision = DebuggerRuntimeModuleInventoryRevision(rawValue: 4)
        let instanceID = DebuggerRuntimeModuleInstanceID(
            processID: 222,
            stop: stop,
            inventoryRevision: inventoryRevision,
            ordinal: 0
        )
        let artifactIdentity = try MachOSliceArtifactIdentity(
            uuid: UUID(uuidString: "34343434-3434-3434-3434-343434343434"),
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: String(repeating: "a", count: 64),
            selectedSliceByteCount: 0x1000
        )
        let coordinate = DebuggerWorkspaceArtifactCoordinate(
            binaryID: UUID(uuidString: "56565656-5656-5656-5656-565656565656")!,
            slot: .primary,
            artifactIdentity: artifactIdentity,
            ownerRevision: .init(rawValue: 1)
        )
        let resolved = DebuggerResolvedRuntimeAddress(
            projectionKey: DebuggerRuntimeMappingProjectionKey(
                stopCoordinate: stop,
                observedPID: 222,
                authorityRevision: .init(rawValue: 5),
                inventoryRevision: inventoryRevision,
                workspaceCatalogRevision: .init(rawValue: 6)
            ),
            moduleInstanceID: instanceID,
            workspaceCoordinate: coordinate,
            imageAddress: ImageAddress(slot: .primary, address: 0x1000),
            runtimeAddress: runtimeAddress
        )
        return try DebuggerRunToCursorRequest(
            resolvedAddress: resolved,
            observedStopID: observedStopID
        )
    }

    // MARK: - Conditional breakpoint editing (parse + round-trip)

    func testBreakpointEditParseNormalizesConditionAndIgnoreCount() {
        let result = DebuggerBreakpointEdit.parse(
            address: 0x1000_0010,
            conditionText: "  x0 == 1  ",
            ignoreCountText: " 3 "
        )
        guard case .success(let edit) = result else {
            return XCTFail("Expected a valid edit, got \(result)")
        }
        XCTAssertEqual(edit.condition, "x0 == 1")
        XCTAssertEqual(edit.ignoreCount, 3)
    }

    func testBreakpointEditParseClearsBlankConditionAndDefaultsIgnore() {
        let result = DebuggerBreakpointEdit.parse(
            address: 0x10,
            conditionText: "   ",
            ignoreCountText: ""
        )
        guard case .success(let edit) = result else {
            return XCTFail("Expected a valid edit, got \(result)")
        }
        XCTAssertNil(edit.condition)
        XCTAssertEqual(edit.ignoreCount, 0)
    }

    func testBreakpointEditParseRejectsNegativeAndNonNumericIgnore() {
        if case .success = DebuggerBreakpointEdit.parse(address: 0x10, conditionText: "", ignoreCountText: "-1") {
            XCTFail("Negative ignore count should be rejected.")
        }
        if case .success = DebuggerBreakpointEdit.parse(address: 0x10, conditionText: "", ignoreCountText: "abc") {
            XCTFail("Non-numeric ignore count should be rejected.")
        }
    }

    func testBreakpointEditParseRejectsIgnoreCountAboveUInt32Max() {
        // LLDB's --ignore-count is a uint32; a larger value would be silently
        // truncated (firing the breakpoint far sooner than intended), so reject it.
        let tooLarge = String(UInt64(UInt32.max) + 1)
        if case .success = DebuggerBreakpointEdit.parse(address: 0x10, conditionText: "", ignoreCountText: tooLarge) {
            XCTFail("Ignore count above UInt32.max should be rejected.")
        }
        // The boundary value itself is accepted.
        guard case let .success(edit) = DebuggerBreakpointEdit.parse(
            address: 0x10, conditionText: "", ignoreCountText: String(UInt32.max)
        ) else {
            return XCTFail("UInt32.max ignore count should be accepted.")
        }
        XCTAssertEqual(edit.ignoreCount, Int(UInt32.max))
    }

    func testBreakpointEditParseRejectsControlCharactersInCondition() {
        if case .success = DebuggerBreakpointEdit.parse(address: 0x10, conditionText: "x0\n== 1", ignoreCountText: "") {
            XCTFail("Embedded newline in condition should be rejected.")
        }
    }

    func testBreakpointEditAppliedPreservesEnabledAndHitCount() {
        let existing = DebuggerBreakpoint(address: 0x20, isEnabled: false, condition: "old", hitCount: 7, ignoreCount: 1)
        let edit = DebuggerBreakpointEdit(address: 0x20, condition: "new", ignoreCount: 4)
        let updated = edit.applied(to: existing)
        XCTAssertEqual(updated.address, 0x20)
        XCTAssertFalse(updated.isEnabled)
        XCTAssertEqual(updated.hitCount, 7)
        XCTAssertEqual(updated.condition, "new")
        XCTAssertEqual(updated.ignoreCount, 4)
    }

    func testViewModelApplyBreakpointEditRoundTripsLocallyWithoutBackendCall() async {
        let client = AuthoringRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        viewModel.beginEditingBreakpoint(at: 0x1000_0010)
        XCTAssertEqual(viewModel.breakpointEditAddressText, 0x1000_0010.hexAddress)
        viewModel.breakpointConditionText = "x0 == 42"
        viewModel.breakpointIgnoreCountText = "2"

        XCTAssertTrue(viewModel.canApplyBreakpointEdit)
        await viewModel.applyBreakpointEdit()

        XCTAssertNil(viewModel.lastError)
        let stored = viewModel.session.breakpoints.first { $0.address == 0x1000_0010 }
        XCTAssertEqual(stored?.condition, "x0 == 42")
        XCTAssertEqual(stored?.ignoreCount, 2)
        XCTAssertTrue(stored?.isEnabled ?? false)
        XCTAssertEqual(client.replaceBreakpointsCallCount, 0)
        XCTAssertNil(client.lastReplacedBreakpoints)
    }

    func testViewModelToggleBreakpointUpdatesLocalStateWithoutBackendCall() async {
        let client = AuthoringRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        await viewModel.toggleBreakpoint(at: 0x1000_0040)

        XCTAssertTrue(viewModel.session.breakpoints.contains { $0.address == 0x1000_0040 })
        XCTAssertEqual(client.replaceBreakpointsCallCount, 0)
        XCTAssertNil(client.lastReplacedBreakpoints)
    }

    func testViewModelApplyBreakpointEditRejectsUnknownAddress() async {
        let client = AuthoringRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        viewModel.breakpointEditAddressText = "0xdeadbeef"
        viewModel.breakpointConditionText = "x0 == 1"
        await viewModel.applyBreakpointEdit()

        XCTAssertEqual(viewModel.lastError, "No breakpoint exists at \(UInt64(0xdead_beef).hexAddress).")
        XCTAssertEqual(client.replaceBreakpointsCallCount, 0)
    }

    func testViewModelApplyBreakpointEditDoesNotTouchBackendWhenNotLive() async {
        // No live process -> reconcile into the session only, never call backend.
        let idleSnapshot = DebuggerSessionSnapshot(
            processState: .notAttached,
            breakpoints: [DebuggerBreakpoint(address: 0x40)],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Idle."
        )
        let client = AuthoringRecordingDebuggerClient(initialSnapshot: idleSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        viewModel.beginEditingBreakpoint(at: 0x40)
        viewModel.breakpointConditionText = "x1 != 0"
        await viewModel.applyBreakpointEdit()

        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(viewModel.session.breakpoints.first?.condition, "x1 != 0")
        XCTAssertEqual(client.replaceBreakpointsCallCount, 0)
    }

    // MARK: - Register write

    func testRegisterWriteRequestParseAcceptsHexAndDecimal() {
        guard case .success(let hex) = DebuggerRegisterWriteRequest.parse(name: "x0", value: "0x2a") else {
            return XCTFail("Hex value should parse.")
        }
        XCTAssertEqual(hex, DebuggerRegisterWriteRequest(name: "x0", value: "0x2a"))

        guard case .success(let decimal) = DebuggerRegisterWriteRequest.parse(name: " pc ", value: " 42 ") else {
            return XCTFail("Decimal value should parse.")
        }
        XCTAssertEqual(decimal.name, "pc")
        XCTAssertEqual(decimal.value, "42")
    }

    func testRegisterWriteRequestParseRejectsBadNameAndValue() {
        if case .success = DebuggerRegisterWriteRequest.parse(name: "", value: "1") {
            XCTFail("Empty register name should be rejected.")
        }
        if case .success = DebuggerRegisterWriteRequest.parse(name: "x 0", value: "1") {
            XCTFail("Register name with a space should be rejected.")
        }
        if case .success = DebuggerRegisterWriteRequest.parse(name: "123", value: "1") {
            XCTFail("Purely numeric register name should be rejected.")
        }
        if case .success = DebuggerRegisterWriteRequest.parse(name: "x0", value: "zzz") {
            XCTFail("Non-numeric value should be rejected.")
        }
        if case .success = DebuggerRegisterWriteRequest.parse(name: "x0", value: "") {
            XCTFail("Empty value should be rejected.")
        }
    }

    func testViewModelWriteRegisterFormsClientCallInPausedLiveSession() async {
        let client = AuthoringRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertTrue(viewModel.canWriteRegister)
        XCTAssertTrue(viewModel.controlAvailability(for: .writeRegister).isEnabled)

        viewModel.registerWriteNameText = "x0"
        viewModel.registerWriteValueText = "0x2a"
        await viewModel.writeRegister()

        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(client.writeRegisterCallCount, 1)
        XCTAssertEqual(client.lastRegisterWrite, DebuggerRegisterWriteRequest(name: "x0", value: "0x2a"))
    }

    func testViewModelWriteRegisterRejectsInvalidInputWithoutClientCall() async {
        let client = AuthoringRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        viewModel.registerWriteNameText = "x0"
        viewModel.registerWriteValueText = "not-a-number"
        await viewModel.writeRegister()

        XCTAssertEqual(client.writeRegisterCallCount, 0)
        XCTAssertTrue(viewModel.lastError?.contains("hex") ?? false)
    }

    func testViewModelWriteRegisterGatedOffWhenNotPausedLive() async {
        // Running (not paused) live process -> register write disabled and the
        // action surfaces the state reason without reaching the client.
        let runningSnapshot = DebuggerSessionSnapshot(
            processState: .running(processID: 222, executableName: "echo"),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Running.",
            backendState: .connected(processID: 222, adapterName: "Authoring Recording LLDB")
        )
        let client = AuthoringRecordingDebuggerClient(initialSnapshot: runningSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertFalse(viewModel.canWriteRegister)
        XCTAssertFalse(viewModel.controlAvailability(for: .writeRegister).isEnabled)

        viewModel.registerWriteNameText = "x0"
        viewModel.registerWriteValueText = "1"
        await viewModel.writeRegister()

        XCTAssertEqual(client.writeRegisterCallCount, 0)
        XCTAssertEqual(viewModel.lastError, "Register write requires a paused live debug process.")
    }

    func testViewModelWriteRegisterPreservedStateWhenBackendUnsupported() async {
        let client = AuthoringUnsupportedControlDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertFalse(viewModel.canWriteRegister)
        viewModel.registerWriteNameText = "x0"
        viewModel.registerWriteValueText = "1"
        await viewModel.writeRegister()

        XCTAssertEqual(client.writeRegisterCallCount, 0)
        XCTAssertTrue(viewModel.lastError?.hasPrefix("Register write unavailable:") ?? false)
    }

    // MARK: - Memory read

    func testMemoryReadRequestParseAcceptsHexAddressAndDefaultsCount() {
        guard case .success(let request) = DebuggerMemoryReadRequest.parse(
            addressText: " 0x100003f80 ",
            byteCountText: ""
        ) else {
            return XCTFail("Hex address should parse.")
        }
        XCTAssertEqual(request.address, 0x1_0000_3f80)
        XCTAssertEqual(request.byteCount, DebuggerMemoryReadRequest.defaultByteCount)
    }

    func testMemoryReadRequestParseRejectsBadAddressAndCount() {
        if case .success = DebuggerMemoryReadRequest.parse(addressText: "", byteCountText: "") {
            XCTFail("Empty address should be rejected.")
        }
        if case .success = DebuggerMemoryReadRequest.parse(addressText: "100", byteCountText: "") {
            XCTFail("Bare decimal address (no 0x) should be rejected.")
        }
        if case .success = DebuggerMemoryReadRequest.parse(addressText: "0xZZ", byteCountText: "") {
            XCTFail("Non-hex address body should be rejected.")
        }
        if case .success = DebuggerMemoryReadRequest.parse(addressText: "0x10", byteCountText: "0") {
            XCTFail("Zero byte count should be rejected.")
        }
        if case .success = DebuggerMemoryReadRequest.parse(addressText: "0x10", byteCountText: "99999") {
            XCTFail("Over-bound byte count should be rejected.")
        }
        if case .success = DebuggerMemoryReadRequest.parse(addressText: "0x10", byteCountText: "abc") {
            XCTFail("Non-numeric byte count should be rejected.")
        }
    }

    func testParseMemorySummariesStopsAtAGapAndDoesNotMergeNonContiguousRuns() {
        // An authored read that crosses an unmapped boundary makes LLDB emit a gap.
        // The parser must report only the CONTIGUOUS run from the base address, not
        // merge the later bytes as if they lived right after the first run.
        let transcript = """
        0x0000000100001000: 01 02 03 04 05 06 07 08
        0x0000000100001008: 09 0a 0b 0c 0d 0e 0f 10
        0x0000000100002000: ff ff ff ff
        """
        let summaries = XcodeLLDBCommandLineAdapter.parseMemorySummaries(from: transcript)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.address, 0x1_0000_1000)
        XCTAssertEqual(summaries.first?.byteCount, 16, "only the contiguous 0x1000..0x1010 run is reported")
        XCTAssertEqual(summaries.first?.previewBytes.last, 0x10)
        XCTAssertFalse(summaries.first?.previewBytes.contains(0xff) ?? true,
                       "bytes past the gap must not be merged in")
    }

    func testViewModelReadMemoryFormsClientCallInPausedLiveSession() async {
        let client = AuthoringRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertTrue(viewModel.canReadMemory)
        viewModel.memoryReadAddressText = "0x100003f80"
        viewModel.memoryReadByteCountText = "16"
        await viewModel.readMemory()

        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(client.readMemoryCallCount, 1)
        XCTAssertEqual(client.lastMemoryRead, DebuggerMemoryReadRequest(address: 0x1_0000_3f80, byteCount: 16))
    }

    func testViewModelReadMemoryGatedOffWhenNotPausedLive() async {
        // Mismatched backend pid -> not a live session -> read disabled and the
        // action does not reach the client.
        let mismatched = DebuggerSessionSnapshot(
            processState: .paused(processID: 222, reason: .userRequested),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused.",
            backendState: .connected(processID: 999, adapterName: "Authoring Recording LLDB")
        )
        let client = AuthoringRecordingDebuggerClient(initialSnapshot: mismatched)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertFalse(viewModel.canReadMemory)
        viewModel.memoryReadAddressText = "0x100003f80"
        await viewModel.readMemory()

        XCTAssertEqual(client.readMemoryCallCount, 0)
        XCTAssertEqual(viewModel.lastError, "Memory read requires a paused live debug process.")
    }

    func testControlActionTitlesForAuthoringActions() {
        XCTAssertEqual(DebuggerControlAction.writeRegister.title, "Write Register")
        XCTAssertEqual(DebuggerControlAction.readMemory.title, "Read Memory")
        XCTAssertEqual(DebuggerControlAction.writeMemory.title, "Write Memory")
    }

    // MARK: - Memory write

    func testMemoryWriteRequestParseAcceptsPrefixedAndBareHexBytes() {
        guard case .success(let request) = DebuggerMemoryWriteRequest.parse(
            addressText: " 0x100003f80 ",
            bytesText: "0x2a ff 0x00, 7"
        ) else {
            return XCTFail("Mixed prefixed/bare hex bytes should parse.")
        }
        XCTAssertEqual(request.address, 0x1_0000_3f80)
        XCTAssertEqual(request.bytes, [0x2a, 0xff, 0x00, 0x07])
        XCTAssertEqual(request.byteCount, 4)
        // Each byte renders as a fixed two-digit 0x literal regardless of how it
        // was typed, so the LLDB command is unambiguous.
        XCTAssertEqual(request.lldbValueTokens, ["0x2a", "0xff", "0x00", "0x07"])
    }

    func testMemoryWriteRequestParseRejectsBadAddressBytesAndOverflow() {
        if case .success = DebuggerMemoryWriteRequest.parse(addressText: "", bytesText: "0x2a") {
            XCTFail("Empty address should be rejected.")
        }
        if case .success = DebuggerMemoryWriteRequest.parse(addressText: "100", bytesText: "0x2a") {
            XCTFail("Bare decimal address (no 0x) should be rejected.")
        }
        if case .success = DebuggerMemoryWriteRequest.parse(addressText: "0x10", bytesText: "") {
            XCTFail("Empty byte list should be rejected.")
        }
        if case .success = DebuggerMemoryWriteRequest.parse(addressText: "0x10", bytesText: "0x100") {
            XCTFail("A value that does not fit in one byte should be rejected.")
        }
        if case .success = DebuggerMemoryWriteRequest.parse(addressText: "0x10", bytesText: "0xzz") {
            XCTFail("A non-hex byte should be rejected.")
        }
        if case .success = DebuggerMemoryWriteRequest.parse(addressText: "0x10", bytesText: "256") {
            XCTFail("A bare value above 0xff should be rejected (bytes are hex).")
        }
    }

    func testMemoryWriteCommandFormsByteGranularWrite() {
        guard case .success(let request) = DebuggerMemoryWriteRequest.parse(
            addressText: "0x100003f80",
            bytesText: "0x2a 0xff"
        ) else {
            return XCTFail("Byte list should parse.")
        }
        XCTAssertEqual(
            XcodeLLDBCommandLineAdapter.makeMemoryWriteCommand(for: request),
            "memory write --size 1 0x0000000100003f80 0x2a 0xff"
        )
        XCTAssertEqual(
            XcodeLLDBCommandLineAdapter.makeMemoryWriteReadBackCommand(for: request),
            "memory read --format x --size 1 --count 2 0x0000000100003f80"
        )
    }

    func testViewModelWriteMemoryFormsClientCallInPausedLiveSession() async {
        let client = AuthoringRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertTrue(viewModel.canWriteMemory)
        XCTAssertTrue(viewModel.controlAvailability(for: .writeMemory).isEnabled)

        viewModel.memoryWriteAddressText = "0x100003f80"
        viewModel.memoryWriteBytesText = "0x2a 0xff"
        await viewModel.writeMemory()

        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(client.writeMemoryCallCount, 1)
        XCTAssertEqual(
            client.lastMemoryWrite,
            DebuggerMemoryWriteRequest(address: 0x1_0000_3f80, bytes: [0x2a, 0xff])
        )
    }

    func testViewModelWriteMemoryRejectsInvalidInputWithoutClientCall() async {
        let client = AuthoringRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        viewModel.memoryWriteAddressText = "0x100003f80"
        viewModel.memoryWriteBytesText = "0xzz"
        await viewModel.writeMemory()

        XCTAssertEqual(client.writeMemoryCallCount, 0)
        XCTAssertTrue(viewModel.lastError?.contains("hex byte") ?? false)
    }

    func testViewModelWriteMemoryGatedOffWhenNotPausedLive() async {
        let runningSnapshot = DebuggerSessionSnapshot(
            processState: .running(processID: 222, executableName: "echo"),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Running.",
            backendState: .connected(processID: 222, adapterName: "Authoring Recording LLDB")
        )
        let client = AuthoringRecordingDebuggerClient(initialSnapshot: runningSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertFalse(viewModel.canWriteMemory)
        XCTAssertFalse(viewModel.controlAvailability(for: .writeMemory).isEnabled)

        viewModel.memoryWriteAddressText = "0x100003f80"
        viewModel.memoryWriteBytesText = "0x2a"
        await viewModel.writeMemory()

        XCTAssertEqual(client.writeMemoryCallCount, 0)
        XCTAssertEqual(viewModel.lastError, "Memory write requires a paused live debug process.")
    }

    func testViewModelWriteMemoryPreservedStateWhenBackendUnsupported() async {
        let client = AuthoringUnsupportedControlDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertFalse(viewModel.canWriteMemory)
        viewModel.memoryWriteAddressText = "0x100003f80"
        viewModel.memoryWriteBytesText = "0x2a"
        await viewModel.writeMemory()

        XCTAssertEqual(client.writeMemoryCallCount, 0)
        XCTAssertTrue(viewModel.lastError?.hasPrefix("Memory write unavailable:") ?? false)
    }

    // MARK: - Full ARM64 register groups

    func testLiveRegisterReadCommandCoversFullARM64RegisterFile() {
        let command = XcodeLLDBCommandLineAdapter.liveRegisterReadCommand
        // Full GPR set x0-x28 plus the named control registers.
        for index in 0...28 {
            XCTAssertTrue(command.contains(" x\(index)"), "GPR x\(index) should be read.")
        }
        for control in ["pc", "sp", "fp", "lr", "cpsr"] {
            XCTAssertTrue(command.contains(" \(control)"), "Control register \(control) should be read.")
        }
        // SIMD vectors v0-v31 plus the FP status/control registers.
        for index in 0...31 {
            XCTAssertTrue(command.contains(" v\(index)"), "SIMD v\(index) should be read.")
        }
        for fp in ["fpsr", "fpcr"] {
            XCTAssertTrue(command.contains(" \(fp)"), "FP register \(fp) should be read.")
        }
        // A single transport command (no embedded command separator that LLDB
        // would misparse) issued with a uniform scalar-hex format.
        XCTAssertFalse(command.contains(";"))
        XCTAssertFalse(command.contains("\n"))
        XCTAssertTrue(command.hasPrefix("register read --format x "))
    }

    func testRegisterGroupClassifiesGPRSIMDAndSystemRegisters() {
        XCTAssertEqual(XcodeLLDBCommandLineAdapter.registerGroup(for: "x0"), .generalPurpose)
        XCTAssertEqual(XcodeLLDBCommandLineAdapter.registerGroup(for: "x28"), .generalPurpose)
        XCTAssertEqual(XcodeLLDBCommandLineAdapter.registerGroup(for: "pc"), .generalPurpose)
        XCTAssertEqual(XcodeLLDBCommandLineAdapter.registerGroup(for: "lr"), .generalPurpose)
        XCTAssertEqual(XcodeLLDBCommandLineAdapter.registerGroup(for: "v0"), .floatingPoint)
        XCTAssertEqual(XcodeLLDBCommandLineAdapter.registerGroup(for: "v31"), .floatingPoint)
        XCTAssertEqual(XcodeLLDBCommandLineAdapter.registerGroup(for: "fpcr"), .floatingPoint)
        XCTAssertEqual(XcodeLLDBCommandLineAdapter.registerGroup(for: "fpsr"), .floatingPoint)
        XCTAssertEqual(XcodeLLDBCommandLineAdapter.registerGroup(for: "cpsr"), .system)
        XCTAssertEqual(XcodeLLDBCommandLineAdapter.registerGroup(for: "far"), .system)
        XCTAssertEqual(XcodeLLDBCommandLineAdapter.registerGroup(for: "mystery"), .other)
    }

    func testParseRegisterSummariesAssignsDisplayGroups() {
        let transcript = """
              pc = 0x00000001000003f8 echo`main + 8
              x0 = 0x000000000000002a
              v0 = 0x00000000000000000000000000000001
            fpcr = 0x0000000000000000
            cpsr = 0x0000000060001000
        """
        let registers = XcodeLLDBCommandLineAdapter.parseRegisterSummaries(from: transcript)
        let byName = Dictionary(uniqueKeysWithValues: registers.map { ($0.name, $0.group) })
        XCTAssertEqual(byName["pc"], .generalPurpose)
        XCTAssertEqual(byName["x0"], .generalPurpose)
        XCTAssertEqual(byName["v0"], .floatingPoint)
        XCTAssertEqual(byName["fpcr"], .floatingPoint)
        XCTAssertEqual(byName["cpsr"], .system)
    }

    func testViewModelGroupedRegistersBucketsAndOrdersByGroup() {
        let snapshot = DebuggerSessionSnapshot(
            processState: .paused(processID: 222, reason: .userRequested),
            breakpoints: [],
            frames: [],
            registers: [
                DebuggerRegisterSummary(name: "cpsr", value: "0x0", group: .system),
                DebuggerRegisterSummary(name: "v0", value: "0x1", group: .floatingPoint),
                DebuggerRegisterSummary(name: "x0", value: "0x2a", group: .generalPurpose),
                DebuggerRegisterSummary(name: "x1", value: "0x0", group: .generalPurpose)
            ],
            memoryRegions: [],
            statusMessage: "Paused.",
            backendState: .connected(processID: 222, adapterName: "Authoring Recording LLDB")
        )
        let client = AuthoringRecordingDebuggerClient(initialSnapshot: snapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        let grouped = viewModel.groupedRegisters
        XCTAssertEqual(grouped.map(\.group), [.generalPurpose, .floatingPoint, .system])
        XCTAssertEqual(grouped.first?.registers.map(\.name), ["x0", "x1"])
        XCTAssertEqual(grouped.last?.registers.map(\.name), ["cpsr"])
    }

    // MARK: - Launch configuration authoring (arguments / environment / cwd)

    func testLaunchArgumentParserSplitsPlainWhitespaceSeparatedWords() {
        guard case .success(let words) = DebuggerLaunchArgumentParser.split("  --verbose   input.bin  ") else {
            return XCTFail("Plain arguments should parse.")
        }
        XCTAssertEqual(words, ["--verbose", "input.bin"])
    }

    func testLaunchArgumentParserHandlesEmptyAndWhitespaceOnly() {
        guard case .success(let empty) = DebuggerLaunchArgumentParser.split("") else {
            return XCTFail("Empty arguments should parse to no words.")
        }
        XCTAssertEqual(empty, [])

        guard case .success(let blank) = DebuggerLaunchArgumentParser.split("   \t  ") else {
            return XCTFail("Whitespace-only arguments should parse to no words.")
        }
        XCTAssertEqual(blank, [])
    }

    func testLaunchArgumentParserHonorsSingleAndDoubleQuotes() {
        guard case .success(let words) = DebuggerLaunchArgumentParser.split(#"--name "two words" 'literal $HOME' tail"#) else {
            return XCTFail("Quoted arguments should parse.")
        }
        XCTAssertEqual(words, ["--name", "two words", "literal $HOME", "tail"])
    }

    func testLaunchArgumentParserSupportsAbuttingQuotesAndEmptyQuotedWord() {
        guard case .success(let abutting) = DebuggerLaunchArgumentParser.split(#"a"b c"d"#) else {
            return XCTFail("Abutting quotes should join into one word.")
        }
        XCTAssertEqual(abutting, ["ab cd"])

        // An explicit empty quoted token is a real (empty) argument.
        guard case .success(let emptyToken) = DebuggerLaunchArgumentParser.split(#"first "" last"#) else {
            return XCTFail("Empty quoted token should parse.")
        }
        XCTAssertEqual(emptyToken, ["first", "", "last"])
    }

    func testLaunchArgumentParserHandlesBackslashEscapes() {
        guard case .success(let words) = DebuggerLaunchArgumentParser.split(#"a\ b "c\"d""#) else {
            return XCTFail("Escaped arguments should parse.")
        }
        XCTAssertEqual(words, ["a b", "c\"d"])
    }

    func testLaunchArgumentParserRejectsUnterminatedQuoteAndDanglingEscape() {
        if case .success = DebuggerLaunchArgumentParser.split(#"--name "unterminated"#) {
            XCTFail("Unterminated double quote should be rejected.")
        }
        if case .success = DebuggerLaunchArgumentParser.split("trailing\\") {
            XCTFail("Dangling backslash should be rejected.")
        }
    }

    func testLaunchInvocationDraftParsesEnvironmentAndSkipsBlankRows() {
        let entries = [
            DebuggerEnvironmentEntry(key: " PATH ", value: " /usr/bin "),
            DebuggerEnvironmentEntry(key: "", value: ""), // blank -> skipped
            DebuggerEnvironmentEntry(key: "MODE", value: "fast")
        ]
        guard case .success(let draft) = DebuggerLaunchInvocationDraft.parse(
            argumentsText: "--run",
            environmentEntries: entries,
            workingDirectoryText: ""
        ) else {
            return XCTFail("Valid environment entries should parse.")
        }
        XCTAssertEqual(draft.arguments, ["--run"])
        XCTAssertEqual(draft.environment, ["PATH": "/usr/bin", "MODE": "fast"])
        XCTAssertNil(draft.workingDirectory)
    }

    func testLaunchInvocationDraftRejectsBadEnvironmentKeys() {
        let equalsKey = [DebuggerEnvironmentEntry(key: "A=B", value: "1")]
        if case .success = DebuggerLaunchInvocationDraft.parse(
            argumentsText: "", environmentEntries: equalsKey, workingDirectoryText: ""
        ) {
            XCTFail("An environment key containing '=' should be rejected.")
        }

        let valuedEmptyKey = [DebuggerEnvironmentEntry(key: "  ", value: "orphan")]
        if case .success = DebuggerLaunchInvocationDraft.parse(
            argumentsText: "", environmentEntries: valuedEmptyKey, workingDirectoryText: ""
        ) {
            XCTFail("An empty key with a value should be rejected.")
        }

        let controlKey = [DebuggerEnvironmentEntry(key: "A\nB", value: "1")]
        if case .success = DebuggerLaunchInvocationDraft.parse(
            argumentsText: "", environmentEntries: controlKey, workingDirectoryText: ""
        ) {
            XCTFail("A control character in the key should be rejected.")
        }
    }

    func testLaunchInvocationDraftRejectsDuplicateEnvironmentKeys() {
        let dupes = [
            DebuggerEnvironmentEntry(key: "MODE", value: "a"),
            DebuggerEnvironmentEntry(key: "MODE", value: "b")
        ]
        if case .success = DebuggerLaunchInvocationDraft.parse(
            argumentsText: "", environmentEntries: dupes, workingDirectoryText: ""
        ) {
            XCTFail("Duplicate environment keys should be rejected.")
        }
    }

    func testLaunchInvocationDraftWorkingDirectoryAcceptsAbsoluteAndRejectsRelative() {
        guard case .success(let absolute) = DebuggerLaunchInvocationDraft.parse(
            argumentsText: "", environmentEntries: [], workingDirectoryText: "  /tmp/run  "
        ) else {
            return XCTFail("Absolute working directory should parse.")
        }
        XCTAssertEqual(absolute.workingDirectory, "/tmp/run")

        guard case .success(let tilde) = DebuggerLaunchInvocationDraft.parse(
            argumentsText: "", environmentEntries: [], workingDirectoryText: "~/Projects"
        ) else {
            return XCTFail("Tilde working directory should parse.")
        }
        XCTAssertEqual(tilde.workingDirectory, "~/Projects")

        if case .success = DebuggerLaunchInvocationDraft.parse(
            argumentsText: "", environmentEntries: [], workingDirectoryText: "relative/dir"
        ) {
            XCTFail("Relative working directory should be rejected.")
        }

        // `~user` (another user's home) is NOT accepted — only `~` / `~/…`.
        if case .success = DebuggerLaunchInvocationDraft.parse(
            argumentsText: "", environmentEntries: [], workingDirectoryText: "~other/dir"
        ) {
            XCTFail("~user working directory should be rejected.")
        }
    }

    func testLaunchInvocationDraftRejectsControlCharactersInArguments() {
        // A control character is a literal word char to the splitter, so it would
        // otherwise pass through to the LLDB run-args command unvalidated.
        if case .success = DebuggerLaunchInvocationDraft.parse(
            argumentsText: "good\u{0007}bad", environmentEntries: [], workingDirectoryText: ""
        ) {
            XCTFail("Arguments containing a control character should be rejected.")
        }
        // A carriage return is also caught (the splitter doesn't word-break on it).
        if case .success = DebuggerLaunchInvocationDraft.parse(
            argumentsText: "arg1\rarg2", environmentEntries: [], workingDirectoryText: ""
        ) {
            XCTFail("Arguments containing a carriage return should be rejected.")
        }
    }

    func testLaunchInvocationDraftRejectsEnvironmentKeyStartingWithDash() {
        let dashKey = [DebuggerEnvironmentEntry(key: "-FLAG", value: "1")]
        if case .success = DebuggerLaunchInvocationDraft.parse(
            argumentsText: "", environmentEntries: dashKey, workingDirectoryText: ""
        ) {
            XCTFail("Environment key starting with '-' should be rejected (LLDB flag misparse).")
        }
    }

    func testLaunchInvocationDraftAppliedOverlaysConfiguration() {
        let base = DebuggerLaunchConfiguration(
            executablePath: "/bin/echo",
            arguments: ["old"],
            environment: ["OLD": "1"],
            workingDirectory: "/var/old"
        )
        // A draft with a cwd replaces it...
        let withCwd = DebuggerLaunchInvocationDraft(
            arguments: ["--new"],
            environment: ["NEW": "2"],
            workingDirectory: "/tmp/new"
        ).applied(to: base)
        XCTAssertEqual(withCwd.arguments, ["--new"])
        XCTAssertEqual(withCwd.environment, ["NEW": "2"])
        XCTAssertEqual(withCwd.workingDirectory, "/tmp/new")
        XCTAssertEqual(withCwd.executablePath, "/bin/echo", "executable path is untouched")

        // ...but an empty cwd leaves the configuration's default in place.
        let withoutCwd = DebuggerLaunchInvocationDraft(
            arguments: [],
            environment: [:],
            workingDirectory: nil
        ).applied(to: base)
        XCTAssertEqual(withoutCwd.arguments, [])
        XCTAssertTrue(withoutCwd.environment.isEmpty)
        XCTAssertEqual(withoutCwd.workingDirectory, "/var/old")
    }

    func testViewModelLaunchAppliesAuthoredInvocationToConfiguration() async {
        let client = LaunchRecordingDebuggerClient(initialSnapshot: Self.idleLaunchableSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)
        // `/bin/echo` is a real executable file, so the imported descriptor is
        // launchable without standing up a temporary fixture binary.
        viewModel.importedExecutablePath = "/bin/echo"

        viewModel.launchArgumentsText = #"--port 8080 "log path""#
        viewModel.launchEnvironmentEntries = [
            DebuggerEnvironmentEntry(key: "MODE", value: "fast"),
            DebuggerEnvironmentEntry() // trailing blank row, dropped
        ]
        viewModel.launchWorkingDirectoryText = "/tmp"

        XCTAssertTrue(viewModel.isLaunchInvocationValid)
        XCTAssertTrue(viewModel.canLaunchSelectedTarget)

        await viewModel.launchSelectedTarget()

        XCTAssertNil(viewModel.lastError)
        let configuration = client.lastLaunchConfiguration
        XCTAssertEqual(configuration?.arguments, ["--port", "8080", "log path"])
        XCTAssertEqual(configuration?.environment, ["MODE": "fast"])
        XCTAssertEqual(configuration?.normalizedWorkingDirectory, "/tmp")
    }

    func testViewModelLaunchRejectsMalformedInvocationWithoutClientCall() async {
        let client = LaunchRecordingDebuggerClient(initialSnapshot: Self.idleLaunchableSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.importedExecutablePath = "/bin/echo"

        viewModel.launchArgumentsText = #"--name "unterminated"#

        XCTAssertFalse(viewModel.isLaunchInvocationValid)
        XCTAssertFalse(viewModel.canLaunchSelectedTarget)

        await viewModel.launchSelectedTarget()

        XCTAssertEqual(client.launchCallCount, 0)
        XCTAssertTrue(viewModel.lastError?.contains("unterminated quote") ?? false)
    }

    func testViewModelRemoveEnvironmentEntryKeepsAtLeastOneRow() {
        let client = LaunchRecordingDebuggerClient(initialSnapshot: Self.idleLaunchableSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.launchEnvironmentEntries = [DebuggerEnvironmentEntry(key: "ONLY", value: "1")]
        let id = viewModel.launchEnvironmentEntries[0].id

        viewModel.removeEnvironmentEntry(id: id)

        XCTAssertEqual(viewModel.launchEnvironmentEntries.count, 1)
        XCTAssertTrue(viewModel.launchEnvironmentEntries[0].isBlank)
    }

    // MARK: - Live transport (register write + memory read through the session)

    func testLiveCommandSessionWritesRegisterAndReadsMemoryThroughTransport() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let transport = AuthoringFakeLLDBCommandSessionTransport(responses: [
            // launch setup + launch + status + stopped-refresh
            .empty,
            .empty,
            .launchStoppedAtEntry,
            .statusStopped,
            .backtrace,
            .registers,
            .stackMemory,
            // register write + register re-read
            .registerWriteOK,
            .registers,
            // memory read
            .authoredMemory,
            // memory write + read-back
            .memoryWriteOK,
            .writtenMemoryReadBack
        ])
        let runner = AuthoringFakeDebuggerProcessRunner(result: .successfulProof)
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            lldbExecutablePath: lldbPath,
            processRunner: runner,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: "/tmp/MacScopeAuthoringProof",
            liveSessionFactory: { transport }
        ))

        let launched = try await client.launch(DebuggerLaunchConfiguration(executablePath: "/bin/echo"))
        XCTAssertEqual(launched.processState, .paused(processID: 222, reason: .unknown("Stopped at entry")))

        let afterWrite = try await client.writeRegister(
            DebuggerRegisterWriteRequest(name: "x0", value: "0x2a"),
            from: launched
        )
        XCTAssertEqual(
            afterWrite.lastCommandRun?.commandDisplay,
            "register write x0 0x2a; \(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)"
        )
        XCTAssertTrue(afterWrite.processState.isPaused)

        let afterRead = try await client.readMemory(
            DebuggerMemoryReadRequest(address: 0x1_0000_3f80, byteCount: 8),
            from: afterWrite
        )
        XCTAssertEqual(
            afterRead.lastCommandRun?.commandDisplay,
            "memory read --format x --size 1 --count 8 0x0000000100003f80"
        )
        XCTAssertTrue(afterRead.memoryRegions.contains { $0.address == 0x1_0000_3f80 })

        let afterMemoryWrite = try await client.writeMemory(
            DebuggerMemoryWriteRequest(address: 0x1_0000_3f80, bytes: [0x2a, 0xff]),
            from: afterRead
        )
        XCTAssertEqual(
            afterMemoryWrite.lastCommandRun?.commandDisplay,
            "memory write --size 1 0x0000000100003f80 0x2a 0xff; memory read --format x --size 1 --count 2 0x0000000100003f80"
        )
        XCTAssertTrue(afterMemoryWrite.processState.isPaused)
        // The read-back bytes are reflected in the snapshot's memory region.
        XCTAssertEqual(
            afterMemoryWrite.memoryRegions.first(where: { $0.address == 0x1_0000_3f80 })?.previewBytes,
            [0x2a, 0xff]
        )

        XCTAssertEqual(transport.sentCommands, [
            "settings set use-color false",
            #"target create "/bin/echo""#,
            "process launch --stop-at-entry",
            "process status",
            "thread backtrace",
            "\(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)",
            "memory read --format x --size 1 --count 64 $sp",
            "register write x0 0x2a",
            "\(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)",
            "memory read --format x --size 1 --count 8 0x0000000100003f80",
            "memory write --size 1 0x0000000100003f80 0x2a 0xff",
            "memory read --format x --size 1 --count 2 0x0000000100003f80"
        ])
        XCTAssertEqual(transport.stopCallCount, 0)
    }

    func testLiveCommandSessionRejectsRegisterWriteWhenNotPaused() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let transport = AuthoringFakeLLDBCommandSessionTransport(responses: [])
        let runner = AuthoringFakeDebuggerProcessRunner(result: .successfulProof)
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            lldbExecutablePath: lldbPath,
            processRunner: runner,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: "/tmp/MacScopeAuthoringProof",
            liveSessionFactory: { transport }
        ))

        // A running (not paused) live snapshot -> register write must be rejected
        // at the client gate before any transport command is sent.
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
            _ = try await client.writeRegister(
                DebuggerRegisterWriteRequest(name: "x0", value: "1"),
                from: running
            )
            XCTFail("Register write should be rejected when not paused.")
        } catch let error as DebuggerClientError {
            XCTAssertEqual(error, .invalidState("Register write requires a paused live debug process."))
        }
        XCTAssertTrue(transport.sentCommands.isEmpty)
    }

    // MARK: - Run to cursor (W4-B)

    func testRunToCursorRequestRetainsCompleteAuthorityAndRejectsZeroStopID() throws {
        let request = try runToCursorRequest(runtimeAddress: 0x1_0000_3f80)
        XCTAssertEqual(request.resolvedAddress.runtimeAddress, 0x1_0000_3f80)
        XCTAssertEqual(request.observedStopID, 9)
        XCTAssertEqual(request.displayName, "run to 0x0000000100003f80")

        XCTAssertThrowsError(try runToCursorRequest(
            runtimeAddress: 0x1_0000_3f80,
            observedStopID: 0
        )) { error in
            XCTAssertEqual(
                error as? DebuggerRunToCursorRequestError,
                .invalidObservedStopID
            )
        }
    }

    /// The injected legacy live controller remains useful to test older authoring commands, but
    /// Run to Cursor must fail closed before it can emit an unchecked breakpoint mutation.
    func testLegacyLiveTransportCannotRunToCursor() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let transport = AuthoringFakeLLDBCommandSessionTransport(responses: [
            // launch setup + launch + status + stopped-refresh
            .empty,
            .empty,
            .launchStoppedAtEntry,
            .statusStopped,
            .backtrace,
            .registers,
            .stackMemory,
        ])
        let runner = AuthoringFakeDebuggerProcessRunner(result: .successfulProof)
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            lldbExecutablePath: lldbPath,
            processRunner: runner,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: "/tmp/MacScopeAuthoringProof",
            liveSessionFactory: { transport }
        ))

        let launched = try await client.launch(DebuggerLaunchConfiguration(executablePath: "/bin/echo"))
        XCTAssertTrue(launched.processState.isPaused)

        do {
            _ = try await client.runToCursor(
                try runToCursorRequest(runtimeAddress: 0x1_0000_3f80),
                from: launched
            )
            XCTFail("Legacy live transport must not receive Run to Cursor.")
        } catch let error as DebuggerClientError {
            XCTAssertEqual(
                error,
                .backendUnavailable("Run to cursor requires the checked persistent LLDB transport.")
            )
        }

        XCTAssertEqual(transport.sentCommands, [
            "settings set use-color false",
            #"target create "/bin/echo""#,
            "process launch --stop-at-entry",
            "process status",
            "thread backtrace",
            "\(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)",
            "memory read --format x --size 1 --count 64 $sp"
        ])
        XCTAssertEqual(transport.stopCallCount, 0)
    }

    func testRunToCursorRejectedWhenNotPausedBeforeAnyCommand() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let transport = AuthoringFakeLLDBCommandSessionTransport(responses: [])
        let runner = AuthoringFakeDebuggerProcessRunner(result: .successfulProof)
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            lldbExecutablePath: lldbPath,
            processRunner: runner,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: "/tmp/MacScopeAuthoringProof",
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
            _ = try await client.runToCursor(
                try runToCursorRequest(runtimeAddress: 0x1_0000_3f80),
                from: running
            )
            XCTFail("Run to cursor should be rejected when not paused.")
        } catch let error as DebuggerClientError {
            XCTAssertEqual(error, .invalidState("Run to cursor requires a paused live debug process."))
        }
        XCTAssertTrue(transport.sentCommands.isEmpty)
    }

    func testViewModelBareRunToCursorAddressFailsClosedWithoutClientCall() async {
        let client = AuthoringRecordingDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertTrue(viewModel.canRunToCursor)
        XCTAssertTrue(viewModel.controlAvailability(for: .runToCursor).isEnabled)

        await viewModel.runToCursor(to: 0x1_0000_3f80)

        XCTAssertEqual(
            viewModel.lastError,
            "Run to Cursor requires an image-qualified address and current runtime mapping."
        )
        XCTAssertEqual(client.runToCursorCallCount, 0)
        XCTAssertNil(client.lastRunToCursor)
        XCTAssertTrue(viewModel.session.processState.isPaused)
    }

    func testViewModelBareRunToCursorFailsClosedBeforePausedStateValidation() async {
        let runningSnapshot = DebuggerSessionSnapshot(
            processState: .running(processID: 222, executableName: "echo"),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Running.",
            backendState: .connected(processID: 222, adapterName: "Authoring Recording LLDB")
        )
        let client = AuthoringRecordingDebuggerClient(initialSnapshot: runningSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertFalse(viewModel.canRunToCursor)
        XCTAssertFalse(viewModel.controlAvailability(for: .runToCursor).isEnabled)

        await viewModel.runToCursor(to: 0x1_0000_3f80)

        XCTAssertEqual(client.runToCursorCallCount, 0)
        XCTAssertEqual(
            viewModel.lastError,
            "Run to Cursor requires an image-qualified address and current runtime mapping."
        )
    }

    func testViewModelBareRunToCursorFailsClosedBeforeCapabilityValidation() async {
        let client = AuthoringUnsupportedControlDebuggerClient(initialSnapshot: Self.pausedLiveSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertFalse(viewModel.canRunToCursor)
        await viewModel.runToCursor(to: 0x1_0000_3f80)

        XCTAssertEqual(
            viewModel.lastError,
            "Run to Cursor requires an image-qualified address and current runtime mapping."
        )
    }

    // MARK: - Value formatting (W4-B)

    func testValueFormatRendersHexDecimalSignedAndFloatFor64Bit() {
        // 0xFFFFFFFFFFFFFFFF: unsigned max; signed -1; float (bit-reinterpret) NaN.
        let allOnes: UInt64 = 0xFFFF_FFFF_FFFF_FFFF
        XCTAssertEqual(DebuggerValueFormatter.format(bits: allOnes, bitWidth: 64, as: .hex), "0xffffffffffffffff")
        XCTAssertEqual(DebuggerValueFormatter.format(bits: allOnes, bitWidth: 64, as: .decimal), "18446744073709551615")
        XCTAssertEqual(DebuggerValueFormatter.format(bits: allOnes, bitWidth: 64, as: .signedDecimal), "-1")
        XCTAssertEqual(DebuggerValueFormatter.format(bits: allOnes, bitWidth: 64, as: .float), "nan")
    }

    func testValueFormatSignedDecimalIsWidthCorrect() {
        // 0xFFFFFFFF: as a 32-bit value it is -1; as a 64-bit value it is 4294967295.
        let value: UInt64 = 0xFFFF_FFFF
        XCTAssertEqual(DebuggerValueFormatter.format(bits: value, bitWidth: 32, as: .signedDecimal), "-1")
        XCTAssertEqual(DebuggerValueFormatter.format(bits: value, bitWidth: 64, as: .signedDecimal), "4294967295")
        // And the 32-bit hex form is 8 digits, the 64-bit form 16.
        XCTAssertEqual(DebuggerValueFormatter.format(bits: value, bitWidth: 32, as: .hex), "0xffffffff")
        XCTAssertEqual(DebuggerValueFormatter.format(bits: value, bitWidth: 64, as: .hex), "0x00000000ffffffff")
    }

    func testValueFormatFloatReinterpretsBitPatterns() {
        // IEEE-754 double 1.0 == 0x3FF0000000000000.
        let oneDouble: UInt64 = 0x3FF0_0000_0000_0000
        XCTAssertEqual(DebuggerValueFormatter.format(bits: oneDouble, bitWidth: 64, as: .float), "1.0")
        // IEEE-754 double -2.5 == 0xC004000000000000.
        let negTwoPointFive: UInt64 = 0xC004_0000_0000_0000
        XCTAssertEqual(DebuggerValueFormatter.format(bits: negTwoPointFive, bitWidth: 64, as: .float), "-2.5")
        // IEEE-754 float 1.0 == 0x3F800000 (32-bit width reinterprets as Float).
        let oneFloat: UInt64 = 0x3F80_0000
        XCTAssertEqual(DebuggerValueFormatter.format(bits: oneFloat, bitWidth: 32, as: .float), "1.0")
        // +inf double == 0x7FF0000000000000.
        let infDouble: UInt64 = 0x7FF0_0000_0000_0000
        XCTAssertEqual(DebuggerValueFormatter.format(bits: infDouble, bitWidth: 64, as: .float), "inf")
    }

    func testValueFormatterRawBitsParsesHexDecimalAndSymbolAnnotated() {
        // Canonical hex form.
        XCTAssertEqual(DebuggerValueFormatter.rawBits(from: "0x000000000000002a"), 0x2a)
        // Symbol-annotated value -> only the leading numeric token is read.
        XCTAssertEqual(DebuggerValueFormatter.rawBits(from: "0x0000000180001000 dyld`start + 604"), 0x1_8000_1000)
        // A bare decimal token.
        XCTAssertEqual(DebuggerValueFormatter.rawBits(from: "42"), 42)
        // A purely symbolic value -> nil (the reformatter leaves such values as-is).
        XCTAssertNil(DebuggerValueFormatter.rawBits(from: "main"))
    }

    func testValueFormatterReformatPreservesHexAndLeavesSymbolicUntouched() {
        // Hex format keeps the snapshot's original text verbatim (annotations and all).
        XCTAssertEqual(
            DebuggerValueFormatter.reformat(value: "0x0000000180001000 dyld`start + 604", as: .hex),
            "0x0000000180001000 dyld`start + 604"
        )
        // A symbolic-only value has no numeric token, so any format leaves it as-is.
        XCTAssertEqual(DebuggerValueFormatter.reformat(value: "main", as: .decimal), "main")
        // A numeric value re-renders under decimal.
        XCTAssertEqual(DebuggerValueFormatter.reformat(value: "0x000000000000002a", as: .decimal), "42")
    }

    func testViewModelFormattedRegistersReRenderUnderSelectedFormat() {
        let snapshot = DebuggerSessionSnapshot(
            processState: .paused(processID: 222, reason: .breakpoint(address: 0x1000_0010)),
            breakpoints: [],
            frames: [],
            registers: [
                DebuggerRegisterSummary(name: "x0", value: "0xffffffffffffffff", group: .generalPurpose),
                DebuggerRegisterSummary(name: "w1", value: "0xffffffff", group: .generalPurpose)
            ],
            memoryRegions: [],
            statusMessage: "Paused.",
            backendState: .connected(processID: 222, adapterName: "Authoring Recording LLDB")
        )
        let client = AuthoringRecordingDebuggerClient(initialSnapshot: snapshot)
        let viewModel = DebuggerPanelViewModel(client: client)
        // The recording client's initial snapshot is what the view model starts at.

        // Default format is hex: values unchanged.
        let hexValues = viewModel.formattedGroupedRegisters.flatMap { $0.registers }.map(\.value)
        XCTAssertEqual(hexValues, ["0xffffffffffffffff", "0xffffffff"])

        // Signed decimal: x0 (64-bit) -> -1; w1 (32-bit view) -> -1.
        viewModel.valueFormat = .signedDecimal
        let signedByName = Dictionary(
            uniqueKeysWithValues: viewModel.formattedGroupedRegisters
                .flatMap { $0.registers }
                .map { ($0.name, $0.value) }
        )
        XCTAssertEqual(signedByName["x0"], "-1")
        XCTAssertEqual(signedByName["w1"], "-1")

        // The write-seed helper always returns the canonical hex, never the
        // reformatted display string.
        XCTAssertEqual(viewModel.hexValue(forRegisterNamed: "x0"), "0xffffffffffffffff")
    }

    // MARK: - Shared snapshot fixture

    private static var pausedLiveSnapshot: DebuggerSessionSnapshot {
        DebuggerSessionSnapshot(
            processState: .paused(processID: 222, reason: .breakpoint(address: 0x1000_0010)),
            breakpoints: [DebuggerBreakpoint(address: 0x1000_0010)],
            frames: [],
            registers: [DebuggerRegisterSummary(name: "x0", value: "0x0000000000000001", role: nil)],
            memoryRegions: [],
            statusMessage: "Paused at breakpoint.",
            backendState: .connected(processID: 222, adapterName: "Authoring Recording LLDB")
        )
    }

    /// An idle (not-attached) snapshot whose backend can launch, so the imported
    /// target is selectable and `launchSelectedTarget` reaches the client.
    private static var idleLaunchableSnapshot: DebuggerSessionSnapshot {
        DebuggerSessionSnapshot(
            processState: .notAttached,
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Ready to launch.",
            backendState: .ready(adapterName: "Authoring Launch LLDB")
        )
    }
}

// MARK: - Self-contained test doubles

@MainActor
private final class AuthoringRecordingDebuggerClient: DebuggerClient {
    var continueResult: DebuggerSessionSnapshot?
    var pollHandler: ((DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot)?
    private(set) var pollCallCount = 0
    func pollProcessStatus(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        pollCallCount += 1
        if let pollHandler { return try await pollHandler(snapshot) }
        return snapshot
    }
    private(set) var shutdownCallCount = 0
    private(set) var continueCallCount = 0
    private(set) var stepOverCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var terminateCallCount = 0
    func shutdown() async { shutdownCallCount += 1 }
    private let initialSnapshot: DebuggerSessionSnapshot
    private(set) var writeRegisterCallCount = 0
    private(set) var readMemoryCallCount = 0
    private(set) var writeMemoryCallCount = 0
    private(set) var replaceBreakpointsCallCount = 0
    private(set) var runToCursorCallCount = 0
    private(set) var lastRegisterWrite: DebuggerRegisterWriteRequest?
    private(set) var lastMemoryRead: DebuggerMemoryReadRequest?
    private(set) var lastMemoryWrite: DebuggerMemoryWriteRequest?
    private(set) var lastReplacedBreakpoints: [DebuggerBreakpoint]?
    private(set) var lastRunToCursor: DebuggerRunToCursorRequest?

    init(initialSnapshot: DebuggerSessionSnapshot) {
        self.initialSnapshot = initialSnapshot
    }

    let capabilities = DebuggerCapabilityReport(
        backendName: "Authoring Recording LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: false,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: []
    )

    func makeInitialSnapshot() -> DebuggerSessionSnapshot { initialSnapshot }
    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot { initialSnapshot }
    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        continueCallCount += 1
        return continueResult ?? snapshot
    }
    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        stepOverCallCount += 1
        return snapshot
    }
    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        pauseCallCount += 1
        return snapshot
    }
    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        terminateCallCount += 1
        return snapshot
    }

    func runToCursor(_ request: DebuggerRunToCursorRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        runToCursorCallCount += 1
        lastRunToCursor = request
        var copy = snapshot
        // Model reaching the cursor: the process is paused at the requested
        // address (a fresh breakpoint stop), the user's breakpoint set unchanged.
        let address = request.resolvedAddress.runtimeAddress
        copy.processState = .paused(processID: 222, reason: .breakpoint(address: address))
        copy.frames = [
            DebuggerFrameSummary(index: 0, address: address, functionName: "main", moduleName: nil, sourceLocation: nil)
        ]
        copy.statusMessage = "Ran to \(address.hexAddress)."
        return copy
    }

    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        replaceBreakpointsCallCount += 1
        lastReplacedBreakpoints = breakpoints
        var copy = snapshot
        copy.replaceBreakpoints(breakpoints)
        return copy
    }

    func writeRegister(_ request: DebuggerRegisterWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        writeRegisterCallCount += 1
        lastRegisterWrite = request
        var copy = snapshot
        copy.statusMessage = "Wrote register \(request.displayName)."
        return copy
    }

    func readMemory(_ request: DebuggerMemoryReadRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        readMemoryCallCount += 1
        lastMemoryRead = request
        var copy = snapshot
        copy.memoryRegions = [
            DebuggerMemorySummary(
                address: request.address,
                byteCount: request.byteCount,
                previewBytes: Array(repeating: 0, count: request.byteCount),
                label: "authored read"
            )
        ]
        return copy
    }

    func writeMemory(_ request: DebuggerMemoryWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        writeMemoryCallCount += 1
        lastMemoryWrite = request
        var copy = snapshot
        copy.memoryRegions = [
            DebuggerMemorySummary(
                address: request.address,
                byteCount: request.byteCount,
                previewBytes: request.bytes,
                label: "authored write"
            )
        ]
        copy.statusMessage = "Wrote \(request.byteCount) byte\(request.byteCount == 1 ? "" : "s") at \(request.address.hexAddress)."
        return copy
    }

    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
}

@MainActor
private final class RetirementSuspension {
    private var suspended: CheckedContinuation<Void, Never>?
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var entered = false

    func suspend() async {
        await withCheckedContinuation { continuation in
            suspended = continuation
            entered = true
            enteredWaiter?.resume()
            enteredWaiter = nil
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func resume() {
        suspended?.resume()
        suspended = nil
    }
}

@MainActor
private final class DebuggerRetirementTestReservations: WorkspaceDocumentLocationReserving {
    func owner(of location: WorkspaceDocumentLocation) -> WorkspaceWindowID? { nil }
    func reserve(_ location: WorkspaceDocumentLocation, for sessionID: WorkspaceDocumentSessionID,
                 windowID: WorkspaceWindowID) -> WorkspaceDocumentLocationReservationResult { .reserved }
    func release(_ location: WorkspaceDocumentLocation, for sessionID: WorkspaceDocumentSessionID) {}
    func releaseAll(for sessionID: WorkspaceDocumentSessionID) {}
    func beginPhysicalPublication(_ staged: WorkspaceDocumentStagedPackage,
        to destination: WorkspaceDocumentLocation, retainingPublishedOwnership: Bool,
        for sessionID: WorkspaceDocumentSessionID,
        windowID: WorkspaceWindowID) -> WorkspaceDocumentPublicationReservationResult {
        .reserved(WorkspaceDocumentPublicationReservation())
    }
    func completePhysicalPublication(_ publication: WorkspaceDocumentPublicationReservation,
        at publishedLocation: WorkspaceDocumentLocation) -> WorkspaceDocumentPublicationCompletionResult { .completed }
    func cancelPhysicalPublication(_ publication: WorkspaceDocumentPublicationReservation) {}
}

/// Records the exact configuration passed to `launch`, with a backend that
/// reports launch support so `launchSelectedTarget` exercises the authored
/// invocation overlay end to end.
@MainActor
private final class LaunchRecordingDebuggerClient: DebuggerClient {
    private let initialSnapshot: DebuggerSessionSnapshot
    private(set) var launchCallCount = 0
    private(set) var lastLaunchConfiguration: DebuggerLaunchConfiguration?

    init(initialSnapshot: DebuggerSessionSnapshot) {
        self.initialSnapshot = initialSnapshot
    }

    let capabilities = DebuggerCapabilityReport(
        backendName: "Authoring Launch LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: false,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: []
    )

    func makeInitialSnapshot() -> DebuggerSessionSnapshot { initialSnapshot }

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot {
        launchCallCount += 1
        lastLaunchConfiguration = configuration
        var copy = initialSnapshot
        copy.processState = .running(processID: 333, executableName: configuration.displayName)
        copy.backendState = .connected(processID: 333, adapterName: "Authoring Launch LLDB")
        return copy
    }

    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func writeRegister(_ request: DebuggerRegisterWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func readMemory(_ request: DebuggerMemoryReadRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
}

@MainActor
private final class AuthoringUnsupportedControlDebuggerClient: DebuggerClient {
    private let initialSnapshot: DebuggerSessionSnapshot
    private(set) var writeRegisterCallCount = 0
    private(set) var readMemoryCallCount = 0
    private(set) var writeMemoryCallCount = 0

    init(initialSnapshot: DebuggerSessionSnapshot) {
        self.initialSnapshot = initialSnapshot
    }

    let capabilities = DebuggerCapabilityReport(
        backendName: "Authoring Batch LLDB",
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

    func writeRegister(_ request: DebuggerRegisterWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        writeRegisterCallCount += 1
        return snapshot
    }

    func readMemory(_ request: DebuggerMemoryReadRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        readMemoryCallCount += 1
        return snapshot
    }

    func writeMemory(_ request: DebuggerMemoryWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        writeMemoryCallCount += 1
        return snapshot
    }

    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
}

private final class AuthoringFakeDebuggerProcessRunner: DebuggerProcessRunning {
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

private final class AuthoringFakeLLDBCommandSessionTransport: DebuggerLLDBCommandSessionTransport {
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
            throw DebuggerLLDBCommandSessionError.writeFailed("Authoring fake transport has no queued response.")
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

    static var registerWriteOK: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "register write x0 0x2a",
            standardOutput: ""
        )
    }

    static var authoredMemory: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "memory read --format x --size 1 --count 8 0x0000000100003f80",
            standardOutput: """
            0x0000000100003f80: 0x2a 0x00 0x00 0x00 0x00 0x00 0x00 0x00
            """
        )
    }

    static var memoryWriteOK: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "memory write --size 1 0x0000000100003f80 0x2a 0xff",
            standardOutput: ""
        )
    }

    static var writtenMemoryReadBack: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "memory read --format x --size 1 --count 2 0x0000000100003f80",
            standardOutput: """
            0x0000000100003f80: 0x2a 0xff
            """
        )
    }

    // MARK: Run-to-cursor fixtures (W4-B)

    static var runToCursorBreakpointSet: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "breakpoint set --one-shot true --address 0x0000000100003f80",
            standardOutput: "Breakpoint 3: where = echo`main + 8, address = 0x0000000100003f80"
        )
    }

    static var runToCursorContinueStoppedAtCursor: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "process continue",
            standardOutput: """
            Process 222 resuming
            Process 222 stopped
            * thread #1, stop reason = breakpoint 3.1
                frame #0: 0x0000000100003f80 echo`main + 8
            """
        )
    }

    static var runToCursorStatusStopped: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "process status",
            standardOutput: """
            Process 222 stopped
            * thread #1, stop reason = breakpoint 3.1
                frame #0: 0x0000000100003f80 echo`main + 8
            """
        )
    }

    static var runToCursorCleanupOK: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "breakpoint delete --force 3",
            standardOutput: "1 breakpoints deleted; 0 breakpoint locations disabled."
        )
    }

    static var runToCursorBacktrace: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "thread backtrace",
            standardOutput: """
            * thread #1, queue = 'com.apple.main-thread'
              * frame #0: 0x0000000100003f80 echo`main + 8 at main.swift:12:5
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
