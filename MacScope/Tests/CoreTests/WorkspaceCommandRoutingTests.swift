import XCTest
@testable import MacScope

/// Reachability + routing tests for the typed `WorkspaceCommand` layer. These fail when a
/// visible command would be dead: no end-to-end effect, no entry point, or an enabled
/// command that silently does nothing. They are the automated guard the stabilization
/// contract asks for — a previously-dead menu command (Mark as Undefined, Add/Remove
/// Bookmark, Patch Bytes, Replace with NOP, Clear Patch) can no longer ship unnoticed.
@MainActor
final class WorkspaceCommandRoutingTests: XCTestCase {

    private func makeStore(addresses: [UInt64] = [0x1000, 0x1004, 0x1008]) -> WorkspaceStore {
        WorkspaceStore(
            workspaceName: "Commands",
            snapshot: WorkspaceSnapshot(
                binaries: [],
                functions: [],
                instructions: addresses.map {
                    InstructionRow(address: $0, bytes: "1f 20 03 d5", mnemonic: "nop",
                                   operands: "", hasBreakpoint: false, comment: nil)
                },
                xrefs: [],
                hexBytes: Data()
            ),
            engine: AnalysisEngine()
        )
    }

    // MARK: - Entry points

    /// Every command has a distinct notification entry point — so a command added without a
    /// user entry point (or colliding with another) is caught here, and the single merged
    /// observer in `WorkspaceCommandHandlers` wires all of them.
    func testEveryCommandHasDistinctNotificationEntryPoint() {
        XCTAssertFalse(WorkspaceCommand.allCases.isEmpty)
        let names = WorkspaceCommand.allCases.map(\.notificationName)
        XCTAssertEqual(Set(names).count, WorkspaceCommand.allCases.count,
                       "Each WorkspaceCommand must map to a unique notification entry point")
        for command in WorkspaceCommand.allCases {
            XCTAssertFalse(command.title.isEmpty)
        }
    }

    func testNativeControlsRouteOnlyToFocusedWindowWithTypedEnablementAndNoEscapeShortcut() throws {
        let nativeCommands: [WorkspaceCommand] = [
            .nativeRequest,
            .nativeRetry,
            .nativeRefresh,
            .nativeCancel,
        ]
        XCTAssertEqual(
            nativeCommands.map(\.notificationName),
            [
                .macScopeNativeRequest,
                .macScopeNativeRetry,
                .macScopeNativeRefresh,
                .macScopeNativeCancel,
            ]
        )
        XCTAssertEqual(Set(nativeCommands.map(\.notificationName)).count, 4)

        let focused = makeStore()
        let sibling = makeStore()
        let note = Notification(
            name: WorkspaceCommand.nativeRequest.notificationName,
            userInfo: Notification.commandTargetUserInfo(focused)
        )
        focused.perform(.nativeRequest, ifTargetedBy: note)
        sibling.perform(.nativeRequest, ifTargetedBy: note)
        XCTAssertNotNil(focused.lastIssue)
        XCTAssertNil(sibling.lastIssue)

        let initial = try NativeDecompilerLayeredPresentationState(
            content: nil,
            intent: .none,
            attempt: .none,
            notice: .none,
            refreshRetentionWitness: nil
        )
        XCTAssertEqual(
            NativeDecompilerCommandAvailability.enabledCommands(
                for: initial,
                context: NativeDecompilerCommandContext(
                    exactTargetEligible: true,
                    retryAuthorityEqual: false,
                    terminalOwner: false
                )
            ),
            [.request]
        )
        var reducer = NativeDecompilerPresentationReducer()
        XCTAssertTrue(reducer.apply(.begin(intent: .request, generation: 1)))
        let running = reducer.state
        XCTAssertEqual(
            NativeDecompilerCommandAvailability.enabledCommands(
                for: running,
                context: NativeDecompilerCommandContext(
                    exactTargetEligible: true,
                    retryAuthorityEqual: false,
                    terminalOwner: false
                )
            ),
            [.cancel]
        )

        let appCommands = try commandSource("App/AppCommands.swift")
        let focusedValues = try commandSource("App/WorkspaceStoreFocusedValue.swift")
        let registry = try commandSource("App/NativeDecompilerRuntimeRegistry.swift")
        let editor = try commandSource("Features/Editor/EditorSurfaceView.swift")
        XCTAssertTrue(appCommands.contains("@FocusedValue(\\.nativeDecompilerCommands)"))
        XCTAssertTrue(focusedValues.contains("NativeDecompilerWindowCommandRouting"))
        XCTAssertTrue(editor.contains(".focusedValue(\\.nativeDecompilerCommands"))
        XCTAssertFalse(appCommands.contains("keyboardShortcut(.escape"))
        for call in [
            "store.requestNativeDecompiler()",
            "store.retryNativeDecompiler()",
            "store.refreshNativeDecompiler()",
            "store.cancelNativeDecompiler()",
        ] {
            XCTAssertTrue(registry.contains(call), "Registry router must delegate through \(call)")
        }
    }

    func testClosingWindowRetiresOnlyItsExactScriptingAuthority() {
        let previous = ScriptingHost.shared.activeStore
        defer { ScriptingHost.shared.activeStore = previous }
        let closing = makeStore()
        let focusedSibling = makeStore()

        ScriptingHost.shared.activeStore = closing
        WorkspaceRootView.retireScriptingAuthority(for: closing)
        XCTAssertNil(ScriptingHost.shared.activeStore)

        ScriptingHost.shared.activeStore = focusedSibling
        WorkspaceRootView.retireScriptingAuthority(for: closing)
        XCTAssertTrue(ScriptingHost.shared.activeStore === focusedSibling)
    }

    // MARK: - Formerly-dead commands now perform real effects

    func testMarkAsUndefinedCommandTogglesUndefined() {
        let store = makeStore()
        store.selectInstruction(0x1000)
        XCTAssertTrue(store.isEnabled(.markAsUndefined))
        store.perform(.markAsUndefined)
        XCTAssertTrue(store.snapshot.isUndefined(at: 0x1000))
        store.perform(.markAsUndefined) // toggles back
        XCTAssertFalse(store.snapshot.isUndefined(at: 0x1000))
    }

    func testMarkAsProcedureCommandTogglesForcedProcedure() {
        let store = makeStore()
        store.selectInstruction(0x1004)
        XCTAssertTrue(store.isEnabled(.markAsProcedure))
        store.perform(.markAsProcedure)
        XCTAssertTrue(store.snapshot.isMarkedAsProcedure(at: 0x1004))
        store.perform(.markAsProcedure) // toggles back
        XCTAssertFalse(store.snapshot.isMarkedAsProcedure(at: 0x1004))
    }

    func testAddAndRemoveBookmarkCommands() {
        let store = makeStore()
        store.selectInstruction(0x1004)
        XCTAssertTrue(store.isEnabled(.addBookmark))
        XCTAssertFalse(store.isEnabled(.removeBookmark)) // none yet
        store.perform(.addBookmark)
        XCTAssertNotNil(store.snapshot.bookmark(at: 0x1004))
        XCTAssertTrue(store.isEnabled(.removeBookmark))
        store.perform(.removeBookmark)
        XCTAssertNil(store.snapshot.bookmark(at: 0x1004))
    }

    func testReplaceWithNOPAndClearPatchCommands() {
        let store = makeStore()
        store.selectInstruction(0x1008)
        XCTAssertTrue(store.isEnabled(.replaceWithNOP))
        XCTAssertFalse(store.isEnabled(.clearPatch)) // nothing patched yet
        store.perform(.replaceWithNOP)
        XCTAssertNotNil(store.snapshot.patch(at: 0x1008))
        XCTAssertTrue(store.isEnabled(.clearPatch))
        store.perform(.clearPatch)
        XCTAssertNil(store.snapshot.patch(at: 0x1008))
    }

    func testPatchBytesCommandPresentsSheet() {
        let store = makeStore()
        store.selectInstruction(0x1000)
        XCTAssertNil(store.pendingPatchBytesRequest)
        store.perform(.patchBytes)
        XCTAssertEqual(store.pendingPatchBytesRequest?.address, 0x1000)
    }

    // MARK: - Disabled-without-context: a guarded, explained no-op (never silent)

    func testCommandsDisabledWithoutSelectionSurfaceAHint() {
        let store = makeStore()
        store.selectedAddress = nil
        let selectionCommands: [WorkspaceCommand] =
            [.markAsUndefined, .markAsProcedure, .addBookmark, .removeBookmark, .patchBytes, .replaceWithNOP, .clearPatch, .assembleInstruction]
        for command in selectionCommands {
            XCTAssertFalse(store.isEnabled(command), "\(command) must be disabled without a selection")
            store.lastIssue = nil
            store.perform(command)
            XCTAssertNotNil(store.lastIssue, "Disabled \(command) must surface a hint, not silently do nothing")
        }
        XCTAssertNil(store.pendingPatchBytesRequest, "A disabled Patch Bytes must not present its sheet")
    }

    // MARK: - Find Next / Find Previous stepping

    func testFindNextPreviousStepWrapAndNavigate() {
        let store = makeStore(addresses: [0x1000, 0x2000, 0x3000])
        XCTAssertFalse(store.isEnabled(.findNext), "Find Next is disabled before a search runs")

        store.seedSearchCursor([
            BinarySearchResult(address: 0x1000, kind: .instruction, preview: "nop"),
            BinarySearchResult(address: 0x2000, kind: .instruction, preview: "nop"),
            BinarySearchResult(address: 0x3000, kind: .instruction, preview: "nop"),
        ])
        XCTAssertTrue(store.isEnabled(.findNext))

        store.perform(.findNext)
        XCTAssertEqual(store.searchCursor?.current?.address, 0x1000)
        XCTAssertEqual(store.selectedAddress, 0x1000) // navigated

        store.perform(.findNext)
        XCTAssertEqual(store.searchCursor?.current?.address, 0x2000)

        store.perform(.findNext) // -> 0x3000
        store.perform(.findNext) // wraps -> 0x1000
        XCTAssertEqual(store.searchCursor?.current?.address, 0x1000)
        XCTAssertEqual(store.selectedAddress, 0x1000)

        store.perform(.findPrevious) // wraps back -> 0x3000
        XCTAssertEqual(store.searchCursor?.current?.address, 0x3000)
        XCTAssertEqual(store.selectedAddress, 0x3000)
    }

    func testEmptySearchClearsCursorAndDisablesStepping() {
        let store = makeStore()
        store.seedSearchCursor([])
        XCTAssertNil(store.searchCursor)
        XCTAssertFalse(store.isEnabled(.findNext))
        XCTAssertFalse(store.isEnabled(.findPrevious))
    }

    // MARK: - Navigate commands (procedures / sections / xrefs)

    /// A store with three procedures, two sections, and two referrers of 0x3000.
    private func makeNavStore() -> WorkspaceStore {
        var snapshot = WorkspaceSnapshot(
            binaries: [],
            functions: [
                FunctionSummary(id: UUID(), name: "a", startAddress: 0x1000, endAddress: 0x2000, confidence: 1),
                FunctionSummary(id: UUID(), name: "b", startAddress: 0x2000, endAddress: 0x3000, confidence: 1),
                FunctionSummary(id: UUID(), name: "c", startAddress: 0x3000, endAddress: 0x4000, confidence: 1),
            ],
            instructions: [0x1000, 0x1100, 0x2000, 0x2100, 0x3000, 0x4000].map {
                InstructionRow(address: $0, bytes: "00 00 00 00", mnemonic: "nop",
                               operands: "", hasBreakpoint: false, comment: nil)
            },
            xrefs: [
                XRef(id: UUID(), from: 0x1100, to: 0x3000, kind: "call"),
                XRef(id: UUID(), from: 0x2100, to: 0x3000, kind: "call"),
            ],
            hexBytes: Data()
        )
        snapshot.sections = [
            SectionSummary(id: UUID(), name: "__text", address: 0x1000, size: 0x3000, fileOffset: 0, isExecutable: true),
            SectionSummary(id: UUID(), name: "__data", address: 0x4000, size: 0x1000, fileOffset: 0x3000, isExecutable: false),
        ]
        return WorkspaceStore(workspaceName: "Nav", snapshot: snapshot, engine: AnalysisEngine())
    }

    func testNextAndPreviousProcedureCommands() {
        let store = makeNavStore()
        store.selectInstruction(0x1000)
        store.perform(.nextProcedure)
        XCTAssertEqual(store.selectedAddress, 0x2000)
        store.perform(.nextProcedure)
        XCTAssertEqual(store.selectedAddress, 0x3000)
        store.perform(.previousProcedure)
        XCTAssertEqual(store.selectedAddress, 0x2000)
    }

    func testTopOfProcedureCommand() {
        let store = makeNavStore()
        store.selectInstruction(0x2100) // inside function b [0x2000, 0x3000)
        XCTAssertTrue(store.isEnabled(.topOfProcedure))
        store.perform(.topOfProcedure)
        XCTAssertEqual(store.selectedAddress, 0x2000)
    }

    func testNextAndPreviousSectionCommands() {
        let store = makeNavStore()
        store.selectInstruction(0x1000)
        store.perform(.nextSection)
        XCTAssertEqual(store.selectedAddress, 0x4000)
        store.perform(.previousSection)
        XCTAssertEqual(store.selectedAddress, 0x1000)
    }

    func testNextAndPreviousXRefCycleReferrers() {
        let store = makeNavStore()
        store.selectInstruction(0x3000) // referred from 0x1100 and 0x2100
        XCTAssertTrue(store.isEnabled(.nextXRef))
        store.perform(.nextXRef)
        XCTAssertEqual(store.selectedAddress, 0x1100) // first referrer (sorted)
        store.perform(.nextXRef)
        XCTAssertEqual(store.selectedAddress, 0x2100) // cursor keeps cycling after navigating
        store.perform(.nextXRef)                       // wraps
        XCTAssertEqual(store.selectedAddress, 0x1100)
        store.perform(.previousXRef)                   // wraps back
        XCTAssertEqual(store.selectedAddress, 0x2100)
    }

    func testNavCommandsDisabledWithoutData() {
        let store = makeStore(addresses: [0x1000]) // no functions/sections/xrefs
        XCTAssertFalse(store.isEnabled(.nextProcedure))
        XCTAssertFalse(store.isEnabled(.nextSection))
        store.selectInstruction(0x1000)
        XCTAssertFalse(store.isEnabled(.topOfProcedure)) // no enclosing function
        XCTAssertFalse(store.isEnabled(.nextXRef))       // no referrers
    }

    // MARK: - Copy commands (clipboard)

    private final class CapturingPasteboard: WorkspacePasteboard {
        var lastString: String?
        func setString(_ string: String) { lastString = string }
    }

    func testCopyAddressCommandCopiesHexAddress() {
        let store = makeStore()
        let pasteboard = CapturingPasteboard()
        store.pasteboard = pasteboard
        store.selectInstruction(0x1004)
        XCTAssertTrue(store.isEnabled(.copyAddress))
        store.perform(.copyAddress)
        XCTAssertEqual(pasteboard.lastString, UInt64(0x1004).hexAddress)
    }

    func testCopyHexStringCommandCopiesSelectedBytes() {
        let store = makeStore() // instructions carry bytes "1f 20 03 d5"
        let pasteboard = CapturingPasteboard()
        store.pasteboard = pasteboard
        store.selectInstruction(0x1000)
        XCTAssertTrue(store.isEnabled(.copyHexString))
        store.perform(.copyHexString)
        XCTAssertEqual(pasteboard.lastString, "1f 20 03 d5")
    }

    func testCopyCommandsDisabledWithoutSelection() {
        let store = makeStore()
        let pasteboard = CapturingPasteboard()
        store.pasteboard = pasteboard
        store.selectedAddress = nil
        XCTAssertFalse(store.isEnabled(.copyAddress))
        XCTAssertFalse(store.isEnabled(.copyHexString))
        store.perform(.copyAddress)
        XCTAssertNil(pasteboard.lastString) // guarded: nothing copied
    }
}

private func commandSource(_ relativePath: String) throws -> String {
    let root = TestSourceRoot.fileURL(#filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: root.appendingPathComponent(relativePath),
        encoding: .utf8
    )
}
