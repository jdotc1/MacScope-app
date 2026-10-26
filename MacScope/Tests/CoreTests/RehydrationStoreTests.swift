import Foundation
import XCTest
@testable import MacScope

/// WS-5 store integration: persisted images reopen with byte-derived products empty, then the
/// store reconstructs and splices those products without disturbing the persisted analysis.
@MainActor
final class RehydrationStoreTests: XCTestCase {
    func testSynchronousRehydrationSplicesDerivedProductsAndPreservesFunctions() async throws {
        let function = FunctionSummary(
            id: UUID(), name: "persisted_function", startAddress: 0x1000,
            endAddress: 0x1010, confidence: 1
        )
        var persisted = ImageAnalysis()
        persisted.functions = [function]
        persisted.sourceLines = [SourceLineEntry(
            address: 0x1000, file: "/src/main.c", line: 42, column: 1, endSequence: false
        )]
        persisted.imageBytes = Data([0xCA, 0xFE])
        let binary = Self.binary(slot: .primary, name: "fixture")
        persisted.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(
            binary: binary,
            analysis: persisted
        )
        let persistedFingerprint = try XCTUnwrap(persisted.analysisInputFingerprint)

        let marker = SectionSummary(
            id: UUID(), name: "rehydrated", address: 0x1000, size: 0x10,
            fileOffset: 0, isExecutable: true
        )
        let provider = ScriptedRehydrationProvider { _, _, preserving, _ in
            var result = preserving
            result.sections = [marker]
            return result
        }
        let store = WorkspaceStore(
            workspaceName: "Rehydration",
            snapshot: WorkspaceSnapshot(binaries: [binary], analysisBySlot: [.primary: persisted]),
            engine: provider,
            autosaveScheduler: nil
        )

        await store.rehydrateLoadedImagesSynchronouslyForTesting()

        let rehydrated = try XCTUnwrap(store.snapshot.analysis(in: .primary))
        XCTAssertEqual(rehydrated.sections, [marker])
        XCTAssertEqual(rehydrated.functions, [function], "persisted products must remain untouched")
        XCTAssertEqual(rehydrated.sourceLines, persisted.sourceLines)
        XCTAssertNotEqual(rehydrated.analysisInputFingerprint, persistedFingerprint)
        XCTAssertEqual(
            rehydrated.analysisInputFingerprint,
            try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: rehydrated)
        )
        XCTAssertEqual(provider.rehydrateCallCount, 1)
        XCTAssertFalse(store.isDirty, "derived-state restoration is not a user mutation")
    }

    func testImageWithoutPersistedBytesIsLeftUntouched() async {
        var persisted = ImageAnalysis()
        persisted.functions = [FunctionSummary(
            id: UUID(), name: "legacy", startAddress: 0x1000, endAddress: 0x1004, confidence: 1
        )]
        let provider = ScriptedRehydrationProvider { _, _, preserving, _ in
            var result = preserving
            result.sections = [SectionSummary(
                id: UUID(), name: "must_not_land", address: 0, size: 1,
                fileOffset: 0, isExecutable: false
            )]
            return result
        }
        let store = WorkspaceStore(
            workspaceName: "No bytes",
            snapshot: Self.snapshot(analysis: persisted),
            engine: provider,
            autosaveScheduler: nil
        )

        await store.rehydrateLoadedImagesSynchronouslyForTesting()

        XCTAssertEqual(store.snapshot.analysis(in: .primary)?.functions, persisted.functions)
        XCTAssertTrue(store.snapshot.analysis(in: .primary)?.sections.isEmpty == true)
        XCTAssertEqual(provider.rehydrateCallCount, 0)
        XCTAssertFalse(store.isDirty)
    }

    func testFailureAddsProblemAndDoesNotAbortOtherImages() async throws {
        let failedSlot = ImageSlot.primary
        let healthySlot = ImageSlot(rawValue: 1)
        var failed = ImageAnalysis()
        failed.imageBytes = Data([0xEE])
        failed.functions = [FunctionSummary(
            id: UUID(), name: "failed_persisted", startAddress: 0x1110,
            endAddress: 0x1120, confidence: 1
        )]
        var healthy = ImageAnalysis()
        healthy.imageBytes = Data([0x01])
        healthy.functions = [FunctionSummary(
            id: UUID(), name: "healthy_persisted", startAddress: 0x2000,
            endAddress: 0x2010, confidence: 1
        )]
        let healthyMarker = SectionSummary(
            id: UUID(), name: "healthy_rehydrated", address: 0x2000, size: 0x10,
            fileOffset: 0, isExecutable: true
        )
        let provider = ScriptedRehydrationProvider { bytes, _, preserving, _ in
            if bytes.first == 0xEE { throw RehydrationStoreTestError.scriptedFailure }
            var result = preserving
            result.sections = [healthyMarker]
            return result
        }
        let snapshot = WorkspaceSnapshot(
            binaries: [
                Self.binary(slot: failedSlot, name: "failed"),
                Self.binary(slot: healthySlot, name: "healthy"),
            ],
            analysisBySlot: [failedSlot: failed, healthySlot: healthy]
        )
        let store = WorkspaceStore(
            workspaceName: "Partial failure", snapshot: snapshot,
            engine: provider, autosaveScheduler: nil
        )

        await store.rehydrateLoadedImagesSynchronouslyForTesting()

        let failedAfter = try XCTUnwrap(store.snapshot.analysis(in: failedSlot))
        XCTAssertTrue(failedAfter.sections.isEmpty)
        XCTAssertEqual(failedAfter.functions, failed.functions)
        let problem = try XCTUnwrap(failedAfter.diagnostics.last)
        XCTAssertEqual(problem.severity, .error)
        XCTAssertEqual(problem.kind, .loaderTruncation)
        XCTAssertEqual(problem.address, 0x1110)
        XCTAssertTrue(problem.message.contains("Couldn’t restore derived analysis"))

        let healthyAfter = try XCTUnwrap(store.snapshot.analysis(in: healthySlot))
        XCTAssertEqual(healthyAfter.sections, [healthyMarker])
        XCTAssertEqual(healthyAfter.functions, healthy.functions)
        XCTAssertEqual(provider.rehydrateCallCount, 2)
        XCTAssertFalse(store.isDirty)
    }

    func testSupersededPassCannotSpliceStaleResultForSameImageIdentity() async throws {
        let gate = RehydrationCallGate()
        let binaryID = UUID()
        let binary = BinaryImage(
            id: binaryID, name: "same", path: "/tmp/same",
            kind: "Mach-O executable", architecture: "arm64", slot: .primary
        )
        let bytes = Data([0xAB, 0xCD])

        func analysis(functionName: String) -> ImageAnalysis {
            var result = ImageAnalysis()
            result.functions = [FunctionSummary(
                id: UUID(), name: functionName, startAddress: 0x1000,
                endAddress: 0x1010, confidence: 1
            )]
            result.imageBytes = bytes
            return result
        }

        let provider = ScriptedRehydrationProvider { _, _, preserving, cancellation in
            var result = preserving
            if preserving.functions.first?.name == "old" {
                gate.enterAndWait()
                gate.recordCancellation(cancellation.isCancelled)
                result.sections = [SectionSummary(
                    id: UUID(), name: "stale", address: 0x1000, size: 0x10,
                    fileOffset: 0, isExecutable: true
                )]
                gate.finishFirstCall()
            } else {
                result.sections = [SectionSummary(
                    id: UUID(), name: "current", address: 0x1000, size: 0x10,
                    fileOffset: 0, isExecutable: true
                )]
            }
            return result
        }
        let store = WorkspaceStore(
            workspaceName: "Epoch",
            snapshot: WorkspaceSnapshot(
                binaries: [binary], analysisBySlot: [.primary: analysis(functionName: "old")]
            ),
            engine: provider,
            autosaveScheduler: nil
        )

        let firstPass = Task { @MainActor in
            await store.rehydrateLoadedImagesSynchronouslyForTesting()
        }
        await Task.detached { gate.waitUntilFirstCallEntered() }.value

        // Same slot, UUID, and bytes: only the generation guard distinguishes this newer restore.
        store.snapshot = WorkspaceSnapshot(
            binaries: [binary], analysisBySlot: [.primary: analysis(functionName: "new")]
        )
        store.rehydrateLoadedImages()
        await store.rehydrateLoadedImagesSynchronouslyForTesting()
        XCTAssertEqual(store.snapshot.analysis(in: .primary)?.sections.first?.name, "current")
        XCTAssertEqual(store.snapshot.analysis(in: .primary)?.functions.first?.name, "new")

        gate.releaseFirstCall()
        await Task.detached { gate.waitUntilFirstCallFinished() }.value
        await firstPass.value

        XCTAssertTrue(gate.firstCallObservedCancellation)
        XCTAssertEqual(store.snapshot.analysis(in: .primary)?.sections.first?.name, "current")
        XCTAssertEqual(store.snapshot.analysis(in: .primary)?.functions.first?.name, "new")
        XCTAssertEqual(provider.rehydrateCallCount, 2)
    }

    func testDeinitCancelsPassWithoutTaskRetainingStore() async {
        let gate = RehydrationCallGate()
        var persisted = ImageAnalysis()
        persisted.imageBytes = Data([0xD1])
        let provider = ScriptedRehydrationProvider { _, _, preserving, cancellation in
            gate.enterAndWait()
            gate.recordCancellation(cancellation.isCancelled)
            gate.finishFirstCall()
            return preserving
        }
        var store: WorkspaceStore? = WorkspaceStore(
            workspaceName: "Deinit",
            snapshot: Self.snapshot(analysis: persisted),
            engine: provider,
            autosaveScheduler: nil
        )
        weak let weakStore = store

        store?.rehydrateLoadedImages()
        await Task.detached { gate.waitUntilFirstCallEntered() }.value
        store = nil

        XCTAssertNil(weakStore, "the retained detached task must not retain its owning store")
        gate.releaseFirstCall()
        await Task.detached { gate.waitUntilFirstCallFinished() }.value
        XCTAssertTrue(gate.firstCallObservedCancellation)
    }

    func testDatabaseWorkspaceRestoreAutomaticallyKicksRehydration() async throws {
        let preservedFunction = FunctionSummary(
            id: UUID(), name: "db_persisted", startAddress: 0x1000,
            endAddress: 0x1010, confidence: 1
        )
        var persisted = ImageAnalysis()
        persisted.imageBytes = Data([0xDB])
        persisted.functions = [preservedFunction]
        let marker = SectionSummary(
            id: UUID(), name: "db_automatic", address: 0x1000, size: 0x10,
            fileOffset: 0, isExecutable: true
        )
        let snapshot = Self.snapshot(analysis: persisted)
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let state = try database.createWorkspaceState(
            workspaceName: "DB hook",
            snapshot: snapshot,
            selectedSidebarItemID: nil,
            selectedAddress: nil,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: ""
        )
        let provider = ScriptedRehydrationProvider { _, _, preserving, _ in
            var result = preserving
            result.sections = [marker]
            return result
        }

        let restored = try XCTUnwrap(WorkspaceStore.restored(
            workspaceID: try XCTUnwrap(state.workspace.id),
            from: database,
            engine: provider
        ))
        await restored.rehydrateLoadedImagesSynchronouslyForTesting()

        let result = try XCTUnwrap(restored.snapshot.analysis(in: .primary))
        XCTAssertEqual(result.sections, [marker])
        XCTAssertEqual(result.functions, [preservedFunction])
        XCTAssertEqual(provider.rehydrateCallCount, 1)
        XCTAssertFalse(restored.isDirty)
    }

    func testPackageRestoreAutomaticallyKicksRehydration() async throws {
        let preservedFunction = FunctionSummary(
            id: UUID(), name: "package_persisted", startAddress: 0x2000,
            endAddress: 0x2010, confidence: 1
        )
        var persisted = ImageAnalysis()
        persisted.imageBytes = Data([0x50])
        persisted.functions = [preservedFunction]
        let marker = SectionSummary(
            id: UUID(), name: "package_automatic", address: 0x2000, size: 0x10,
            fileOffset: 0, isExecutable: true
        )
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let state = try database.createWorkspaceState(
            workspaceName: "Package hook",
            snapshot: Self.snapshot(analysis: persisted),
            selectedSidebarItemID: nil,
            selectedAddress: nil,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: ""
        )
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RehydrationHook-\(UUID().uuidString)")
            .appendingPathExtension(MacScopeDocumentPackage.fileExtension)
        defer { try? FileManager.default.removeItem(at: packageURL) }
        try database.writePackage(
            workspaceID: try XCTUnwrap(state.workspace.id),
            to: packageURL
        )
        let provider = ScriptedRehydrationProvider { _, _, preserving, _ in
            var result = preserving
            result.sections = [marker]
            return result
        }

        let restored = try WorkspaceStore.restoredPackage(from: packageURL, engine: provider)
        await restored.rehydrateLoadedImagesSynchronouslyForTesting()

        let result = try XCTUnwrap(restored.snapshot.analysis(in: .primary))
        XCTAssertEqual(result.sections, [marker])
        XCTAssertEqual(result.functions, [preservedFunction])
        XCTAssertEqual(provider.rehydrateCallCount, 1)
        XCTAssertFalse(restored.isDirty)
    }

    func testDatabaseRestoreDefersMappedUndecodedSelectionUntilRehydration() async throws {
        let selectedAddress: UInt64 = 0x3108
        var persisted = ImageAnalysis()
        persisted.imageBytes = Data([0xDB, 0x01])
        let marker = SectionSummary(
            id: UUID(), name: "db_mapped_data", address: 0x3100, size: 0x20,
            fileOffset: 0, isExecutable: false
        )
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let state = try database.createWorkspaceState(
            workspaceName: "DB mapped selection",
            snapshot: Self.snapshot(analysis: persisted),
            selectedSidebarItemID: nil,
            selectedAddress: selectedAddress,
            selectedTool: .project,
            editorMode: .hex,
            isInspectorPresented: true,
            sidebarSearchText: ""
        )
        let provider = ScriptedRehydrationProvider { _, _, preserving, _ in
            var result = preserving
            result.sections = [marker]
            return result
        }

        let restored = try XCTUnwrap(WorkspaceStore.restored(
            workspaceID: try XCTUnwrap(state.workspace.id),
            from: database,
            engine: provider
        ))
        XCTAssertNil(
            restored.selectedImageAddress,
            "an address not yet proven mapped must remain unavailable before rehydration"
        )

        await restored.rehydrateLoadedImagesSynchronouslyForTesting()

        XCTAssertEqual(
            restored.selectedImageAddress,
            ImageAddress(slot: .primary, address: selectedAddress)
        )
        XCTAssertEqual(provider.rehydrateCallCount, 1)
    }

    func testPackageRestoreDefersMappedUndecodedSelectionUntilRehydration() async throws {
        let selectedAddress: UInt64 = 0x4108
        var persisted = ImageAnalysis()
        persisted.imageBytes = Data([0x50, 0x01])
        let marker = SectionSummary(
            id: UUID(), name: "package_mapped_data", address: 0x4100, size: 0x20,
            fileOffset: 0, isExecutable: false
        )
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let state = try database.createWorkspaceState(
            workspaceName: "Package mapped selection",
            snapshot: Self.snapshot(analysis: persisted),
            selectedSidebarItemID: nil,
            selectedAddress: selectedAddress,
            selectedTool: .project,
            editorMode: .hex,
            isInspectorPresented: true,
            sidebarSearchText: ""
        )
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RehydrationMappedSelection-\(UUID().uuidString)")
            .appendingPathExtension(MacScopeDocumentPackage.fileExtension)
        defer { try? FileManager.default.removeItem(at: packageURL) }
        try database.writePackage(
            workspaceID: try XCTUnwrap(state.workspace.id),
            to: packageURL
        )
        let provider = ScriptedRehydrationProvider { _, _, preserving, _ in
            var result = preserving
            result.sections = [marker]
            return result
        }

        let restored = try WorkspaceStore.restoredPackage(from: packageURL, engine: provider)
        XCTAssertNil(restored.selectedImageAddress)

        await restored.rehydrateLoadedImagesSynchronouslyForTesting()

        XCTAssertEqual(
            restored.selectedImageAddress,
            ImageAddress(slot: .primary, address: selectedAddress)
        )
        XCTAssertEqual(provider.rehydrateCallCount, 1)
    }

    func testInvalidPersistedCoordinateRemainsUnselectedAfterRehydration() async throws {
        let invalidAddress: UInt64 = 0xDEAD_BEEF
        var persisted = ImageAnalysis()
        persisted.imageBytes = Data([0x51, 0x01])
        let provider = ScriptedRehydrationProvider { _, _, preserving, _ in
            var result = preserving
            result.sections = [SectionSummary(
                id: UUID(), name: "non_overlapping", address: 0x5100, size: 0x20,
                fileOffset: 0, isExecutable: false
            )]
            return result
        }
        let restored = try restoredPendingSelectionStore(
            analysis: persisted,
            selectedAddress: invalidAddress,
            engine: provider
        )

        await restored.rehydrateLoadedImagesSynchronouslyForTesting()

        XCTAssertNil(restored.selectedImageAddress)
        XCTAssertFalse(restored.canNavigateBack)
        XCTAssertFalse(restored.canNavigateForward)
    }

    func testExplicitSelectionClearCancelsPendingMappedSelectionRestore() async throws {
        let pendingAddress: UInt64 = 0x5208
        let immediateAddress: UInt64 = 0x5000
        let gate = RehydrationCallGate()
        var persisted = ImageAnalysis()
        persisted.imageBytes = Data([0x52, 0x01])
        persisted.functions = [FunctionSummary(
            id: UUID(), name: "immediate_selection", startAddress: immediateAddress,
            endAddress: immediateAddress + 4, confidence: 1
        )]
        persisted.instructions = [InstructionRow(
            address: immediateAddress,
            bytes: "00 00 00 00",
            mnemonic: "nop",
            operands: "",
            hasBreakpoint: false,
            comment: "IMMEDIATE_SELECTION"
        )]
        let provider = ScriptedRehydrationProvider { _, _, preserving, _ in
            gate.enterAndWait()
            var result = preserving
            result.sections = [SectionSummary(
                id: UUID(), name: "pending_mapped_data", address: 0x5200, size: 0x20,
                fileOffset: 0, isExecutable: false
            )]
            gate.finishFirstCall()
            return result
        }
        let restored = try restoredPendingSelectionStore(
            analysis: persisted,
            selectedAddress: pendingAddress,
            engine: provider
        )
        await Task.detached { gate.waitUntilFirstCallEntered() }.value

        restored.selectInstruction(immediateAddress)
        XCTAssertEqual(restored.selectedAddress, immediateAddress)
        restored.selectedAddress = nil
        gate.releaseFirstCall()
        await Task.detached { gate.waitUntilFirstCallFinished() }.value
        await restored.rehydrateLoadedImagesSynchronouslyForTesting()

        XCTAssertNil(
            restored.selectedImageAddress,
            "an explicit selection change must permanently supersede the persisted pending intent"
        )
        XCTAssertFalse(restored.canNavigateBack)
        XCTAssertFalse(restored.canNavigateForward)
    }

    func testFailedImportRestartsRehydrationWithoutPendingSelection() async throws {
        let gate = RehydrationCallGate()
        var persisted = ImageAnalysis()
        persisted.imageBytes = Data([0x55, 0x01])
        let marker = SectionSummary(
            id: UUID(), name: "failed_import_restart", address: 0x5500, size: 0x20,
            fileOffset: 0, isExecutable: false
        )
        let provider = RehydrationLifecycleProvider(
            gate: gate,
            mappedSection: marker,
            openResult: .failure
        )
        let store = WorkspaceStore(
            workspaceName: "No pending selection",
            snapshot: Self.snapshot(analysis: persisted),
            engine: provider,
            autosaveScheduler: nil
        )
        XCTAssertNil(store.selectedImageAddress)
        store.rehydrateLoadedImages()
        await Task.detached { gate.waitUntilFirstCallEntered() }.value

        await store.importBinary(url: URL(fileURLWithPath: "/tmp/failing-import"))
        await store.awaitCurrentRehydrationForTesting()

        XCTAssertEqual(provider.rehydrateCallCount, 2)
        XCTAssertEqual(store.snapshot.analysis(in: .primary)?.sections, [marker])
        XCTAssertNil(store.selectedImageAddress)
        gate.releaseFirstCall()
        await Task.detached { gate.waitUntilFirstCallFinished() }.value
        XCTAssertTrue(gate.firstCallObservedCancellation)
        XCTAssertEqual(store.snapshot.analysis(in: .primary)?.sections, [marker])
    }

    func testSuccessfulAdditionalImageRestartsExistingImageRehydration() async throws {
        let gate = RehydrationCallGate()
        var persisted = ImageAnalysis()
        persisted.imageBytes = Data([0x56, 0x01])
        let restoredMarker = SectionSummary(
            id: UUID(), name: "existing_image_rehydrated", address: 0x5600, size: 0x20,
            fileOffset: 0, isExecutable: false
        )
        var addedAnalysis = ImageAnalysis()
        addedAnalysis.sections = [SectionSummary(
            id: UUID(), name: "new_image", address: 0x6600, size: 0x20,
            fileOffset: 0, isExecutable: true
        )]
        let addedSnapshot = Self.snapshot(analysis: addedAnalysis)
        let provider = RehydrationLifecycleProvider(
            gate: gate,
            mappedSection: restoredMarker,
            openResult: .success(addedSnapshot)
        )
        let store = WorkspaceStore(
            workspaceName: "Load additional during restore",
            snapshot: Self.snapshot(analysis: persisted),
            engine: provider,
            autosaveScheduler: nil
        )
        store.rehydrateLoadedImages()
        await Task.detached { gate.waitUntilFirstCallEntered() }.value

        await store.loadAdditionalBinary(url: URL(fileURLWithPath: "/tmp/additional-image"))
        await store.awaitCurrentRehydrationForTesting()

        XCTAssertEqual(store.snapshot.binaries.count, 2)
        XCTAssertEqual(store.snapshot.analysis(in: .primary)?.sections, [restoredMarker])
        XCTAssertGreaterThanOrEqual(provider.rehydrateCallCount, 2)
        gate.releaseFirstCall()
        await Task.detached { gate.waitUntilFirstCallFinished() }.value
        XCTAssertTrue(gate.firstCallObservedCancellation)
        XCTAssertEqual(store.snapshot.analysis(in: .primary)?.sections, [restoredMarker])
    }

    func testDisplayOnlyMutationRestartsRehydrationFromCurrentSnapshot() async throws {
        let gate = RehydrationCallGate()
        var persisted = ImageAnalysis()
        persisted.imageBytes = Data([0x57, 0x01])
        let marker = SectionSummary(
            id: UUID(), name: "post_mutation_rehydrated", address: 0x5700, size: 0x20,
            fileOffset: 0, isExecutable: false
        )
        let provider = RehydrationLifecycleProvider(
            gate: gate,
            mappedSection: marker,
            openResult: .failure
        )
        let store = WorkspaceStore(
            workspaceName: "Mutation during restore",
            snapshot: Self.snapshot(analysis: persisted),
            engine: provider,
            autosaveScheduler: nil
        )
        store.rehydrateLoadedImages()
        await Task.detached { gate.waitUntilFirstCallEntered() }.value

        store.addBookmark(at: 0x5708, name: "keep me")
        await store.awaitCurrentRehydrationForTesting()

        XCTAssertEqual(store.snapshot.analysis(in: .primary)?.sections, [marker])
        XCTAssertEqual(store.snapshot.bookmarks.first?.address, 0x5708)
        XCTAssertEqual(store.snapshot.bookmarks.first?.name, "keep me")
        XCTAssertEqual(provider.rehydrateCallCount, 2)
        gate.releaseFirstCall()
        await Task.detached { gate.waitUntilFirstCallFinished() }.value
        XCTAssertTrue(gate.firstCallObservedCancellation)
        XCTAssertEqual(store.snapshot.bookmarks.first?.name, "keep me")
    }

    func testNewerStructuralReanalysisSurvivesLaterRehydrationCompletion() async {
        await assertStructuralReanalysisWins(over: .rehydrationCompletesLast)
    }

    func testNewerStructuralReanalysisWinsAfterEarlierRehydrationCompletion() async {
        await assertStructuralReanalysisWins(over: .reanalysisCompletesLast)
    }

    func testAwaitOnlyRehydrationFollowsReplacementScheduledWhileAwaitingCurrentPass() async {
        let supersededGate = RehydrationCallGate()
        let replacementGate = RehydrationCallGate()
        var persisted = ImageAnalysis()
        persisted.imageBytes = Data([0x5D, 0x01])
        let provider = TwoPassBlockingRehydrationProvider(
            supersededGate: supersededGate,
            replacementGate: replacementGate
        )
        let store = WorkspaceStore(
            workspaceName: "Await replacement rehydration",
            snapshot: Self.snapshot(analysis: persisted),
            engine: provider,
            autosaveScheduler: nil
        )
        let probe = RehydrationAwaitProbe()

        store.rehydrateLoadedImages()
        await Task.detached { supersededGate.waitUntilFirstCallEntered() }.value
        let waiter = Task { @MainActor in
            probe.didStart = true
            await store.awaitCurrentRehydrationForTesting()
            probe.didReturn = true
        }
        // Let the main-actor waiter enter the seam and suspend on pass 1. A cooperative probe keeps
        // this async test off blocking synchronization APIs that Swift 6.4 intentionally makes
        // unavailable from asynchronous contexts.
        for _ in 0..<100 where !probe.didStart { await Task.yield() }
        XCTAssertTrue(probe.didStart, "the await-only seam waiter must start before supersession")

        store.addBookmark(at: 0x5D08, name: "replacement")
        await Task.detached { replacementGate.waitUntilFirstCallEntered() }.value
        supersededGate.releaseFirstCall()
        await Task.detached { supersededGate.waitUntilFirstCallFinished() }.value

        // Drain bounded main-actor continuations. A one-shot await returns here after pass 1; a
        // replacement-safe await remains suspended on the deliberately blocked pass 2.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(
            probe.didReturn,
            "the await-only seam must not return while its replacement rehydration is still running"
        )

        replacementGate.releaseFirstCall()
        await waiter.value
        await Task.detached { replacementGate.waitUntilFirstCallFinished() }.value
        XCTAssertTrue(probe.didReturn)
        XCTAssertEqual(provider.rehydrateCallCount, 2)
        XCTAssertEqual(store.snapshot.bookmarks.first?.name, "replacement")
    }

    func testFailedImportDoesNotCancelUnrelatedStructuralReanalysis() async throws {
        let gate = AsyncAnalysisCallGate()
        var initial = ImageAnalysis()
        initial.imageBytes = Data([0x58, 0x01])
        initial.sections = [SectionSummary(
            id: UUID(), name: "initial", address: 0x5800, size: 0x20,
            fileOffset: 0, isExecutable: true
        )]
        initial.instructions = [InstructionRow(
            address: 0x5800, bytes: "00 00 00 00", mnemonic: "nop", operands: "",
            hasBreakpoint: false, comment: nil
        )]
        var reanalyzed = initial
        let landedMarker = SectionSummary(
            id: UUID(), name: "reanalyzed_after_failed_import", address: 0x5800, size: 0x20,
            fileOffset: 0, isExecutable: true
        )
        reanalyzed.sections = [landedMarker]
        let provider = FailedImportReanalysisProvider(
            gate: gate,
            reanalyzedSnapshot: Self.snapshot(analysis: reanalyzed)
        )
        let store = WorkspaceStore(
            workspaceName: "Reanalysis survives import failure",
            snapshot: Self.snapshot(analysis: initial),
            engine: provider,
            autosaveScheduler: nil
        )

        store.setIsData(0x5800, true)
        await gate.waitUntilEntered()
        await store.importBinary(url: URL(fileURLWithPath: "/tmp/failing-import"))

        XCTAssertTrue(store.isReanalyzing)
        await gate.release()
        await store.awaitPendingReanalysis()
        XCTAssertEqual(store.snapshot.analysis(in: .primary)?.sections, [landedMarker])
        XCTAssertFalse(provider.reanalysisObservedCancellation)
    }

    func testFailedImportRestartsUnchangedWorkspacePendingRehydration() async throws {
        let pendingAddress: UInt64 = 0x5308
        let gate = RehydrationCallGate()
        var persisted = ImageAnalysis()
        persisted.imageBytes = Data([0x53, 0x01])
        let mappedSection = SectionSummary(
            id: UUID(), name: "restart_mapped_data", address: 0x5300, size: 0x20,
            fileOffset: 0, isExecutable: false
        )
        let provider = FailedImportRestartRehydrationProvider(
            gate: gate,
            mappedSection: mappedSection
        )
        let restored = try restoredPendingSelectionStore(
            analysis: persisted,
            selectedAddress: pendingAddress,
            engine: provider
        )
        await Task.detached { gate.waitUntilFirstCallEntered() }.value

        await restored.importBinary(url: URL(fileURLWithPath: "/tmp/failing-import"))
        await restored.awaitCurrentRehydrationForTesting()

        XCTAssertEqual(
            restored.selectedImageAddress,
            ImageAddress(slot: .primary, address: pendingAddress)
        )
        XCTAssertEqual(provider.rehydrateCallCount, 2)
        XCTAssertNotNil(restored.lastIssue)

        gate.releaseFirstCall()
        await Task.detached { gate.waitUntilFirstCallFinished() }.value
        XCTAssertTrue(gate.firstCallObservedCancellation)
        XCTAssertEqual(
            restored.selectedImageAddress,
            ImageAddress(slot: .primary, address: pendingAddress),
            "the cancelled old pass must not clear or replace the restarted result"
        )
    }

    func testSlotRemapCancelsPendingRestoreWithoutLaterResurrection() async throws {
        let pendingAddress: UInt64 = 0x5408
        let remappedSlot = ImageSlot(rawValue: 7)
        let gate = RehydrationCallGate()
        var persisted = ImageAnalysis()
        persisted.imageBytes = Data([0x54, 0x01])
        let provider = FailedImportRestartRehydrationProvider(
            gate: gate,
            mappedSection: SectionSummary(
                id: UUID(), name: "remap_mapped_data", address: 0x5400, size: 0x20,
                fileOffset: 0, isExecutable: false
            )
        )
        let restored = try restoredPendingSelectionStore(
            analysis: persisted,
            selectedAddress: pendingAddress,
            engine: provider
        )
        await Task.detached { gate.waitUntilFirstCallEntered() }.value

        restored.remapImageSlot(from: .primary, to: remappedSlot)
        restored.remapImageSlot(from: remappedSlot, to: .primary)
        await restored.awaitCurrentRehydrationForTesting()

        XCTAssertNil(restored.selectedImageAddress)
        XCTAssertEqual(
            restored.snapshot.analysis(in: .primary)?.sections.first?.name,
            "remap_mapped_data"
        )
        XCTAssertGreaterThanOrEqual(provider.rehydrateCallCount, 2)
        XCTAssertFalse(restored.canNavigateBack)
        XCTAssertFalse(restored.canNavigateForward)
        gate.releaseFirstCall()
        await Task.detached { gate.waitUntilFirstCallFinished() }.value
        XCTAssertTrue(gate.firstCallObservedCancellation)
    }

    func testPendingSelectionIsRetiredWhenOwnerIsRemovedAndReinserted() async throws {
        let pendingAddress: UInt64 = 0x5908
        let gate = RehydrationCallGate()
        var persisted = ImageAnalysis()
        persisted.imageBytes = Data([0x59, 0x01])
        let marker = SectionSummary(
            id: UUID(), name: "reinserted_owner", address: 0x5900, size: 0x20,
            fileOffset: 0, isExecutable: false
        )
        let provider = ScriptedRehydrationProvider { _, _, preserving, cancellation in
            gate.enterAndWait()
            gate.recordCancellation(cancellation.isCancelled)
            var result = preserving
            result.sections = [marker]
            gate.finishFirstCall()
            return result
        }
        let restored = try restoredPendingSelectionStore(
            analysis: persisted,
            selectedAddress: pendingAddress,
            engine: provider
        )
        await Task.detached { gate.waitUntilFirstCallEntered() }.value
        let originalBinary = try XCTUnwrap(restored.snapshot.binary(in: .primary))
        let originalAnalysis = try XCTUnwrap(restored.snapshot.analysis(in: .primary))

        restored.snapshot.removeImage(in: .primary)
        restored.snapshot.insertImage(binary: originalBinary, analysis: originalAnalysis)
        gate.releaseFirstCall()
        await Task.detached { gate.waitUntilFirstCallFinished() }.value
        await restored.awaitCurrentRehydrationForTesting()

        XCTAssertNil(
            restored.selectedImageAddress,
            "removing the pending owner must retire its invisible selection intent"
        )
    }

    func testPendingSelectionIsRetiredAcrossSameSlotOwnerReplacement() async throws {
        let pendingAddress: UInt64 = 0x5A08
        let gate = RehydrationCallGate()
        var persisted = ImageAnalysis()
        persisted.imageBytes = Data([0x5A, 0x01])
        let provider = ScriptedRehydrationProvider { _, _, preserving, cancellation in
            gate.enterAndWait()
            gate.recordCancellation(cancellation.isCancelled)
            var result = preserving
            result.sections = [SectionSummary(
                id: UUID(), name: "same_slot_original", address: 0x5A00, size: 0x20,
                fileOffset: 0, isExecutable: false
            )]
            gate.finishFirstCall()
            return result
        }
        let restored = try restoredPendingSelectionStore(
            analysis: persisted,
            selectedAddress: pendingAddress,
            engine: provider
        )
        await Task.detached { gate.waitUntilFirstCallEntered() }.value
        let originalBinary = try XCTUnwrap(restored.snapshot.binary(in: .primary))

        var replacement = restored.snapshot
        replacement.binaries[0] = Self.binary(slot: .primary, name: "replacement")
        restored.snapshot = replacement
        var originalOwnerReinserted = restored.snapshot
        originalOwnerReinserted.binaries[0] = originalBinary
        restored.snapshot = originalOwnerReinserted

        gate.releaseFirstCall()
        await Task.detached { gate.waitUntilFirstCallFinished() }.value
        await restored.awaitCurrentRehydrationForTesting()

        XCTAssertNil(
            restored.selectedImageAddress,
            "a transient same-slot owner replacement must permanently retire the old intent"
        )
    }

    func testPendingSelectionIsRetiredWhenFocusMovesToAnotherImage() async throws {
        let pendingAddress: UInt64 = 0x5B08
        let secondarySlot = ImageSlot(rawValue: 1)
        let gate = RehydrationCallGate()
        var persisted = ImageAnalysis()
        persisted.imageBytes = Data([0x5B, 0x01])
        let provider = ScriptedRehydrationProvider { _, _, preserving, cancellation in
            gate.enterAndWait()
            gate.recordCancellation(cancellation.isCancelled)
            var result = preserving
            result.sections = [SectionSummary(
                id: UUID(), name: "focus_moved", address: 0x5B00, size: 0x20,
                fileOffset: 0, isExecutable: false
            )]
            gate.finishFirstCall()
            return result
        }
        let restored = try restoredPendingSelectionStore(
            analysis: persisted,
            selectedAddress: pendingAddress,
            engine: provider
        )
        await Task.detached { gate.waitUntilFirstCallEntered() }.value
        var secondaryAnalysis = ImageAnalysis()
        secondaryAnalysis.sections = [SectionSummary(
            id: UUID(), name: "secondary", address: 0x6B00, size: 0x20,
            fileOffset: 0, isExecutable: true
        )]
        restored.snapshot.insertImage(
            binary: Self.binary(slot: secondarySlot, name: "secondary"),
            analysis: secondaryAnalysis
        )

        restored.focusImage(secondarySlot)
        gate.releaseFirstCall()
        await Task.detached { gate.waitUntilFirstCallFinished() }.value
        await restored.awaitCurrentRehydrationForTesting()

        XCTAssertEqual(restored.focusedImageSlot, secondarySlot)
        XCTAssertNil(
            restored.selectedImageAddress,
            "leaving the pending focus domain must prevent later restore-time resurrection"
        )
    }

    func testNewImportCancelsSupersededRehydration() async throws {
        let gate = RehydrationCallGate()
        var oldAnalysis = ImageAnalysis()
        oldAnalysis.imageBytes = Data([0xAA])
        var importedAnalysis = ImageAnalysis()
        importedAnalysis.functions = [FunctionSummary(
            id: UUID(), name: "imported", startAddress: 0x3000,
            endAddress: 0x3010, confidence: 1
        )]
        importedAnalysis.sections = [SectionSummary(
            id: UUID(), name: "imported", address: 0x3000, size: 0x10,
            fileOffset: 0, isExecutable: true
        )]
        let importedSnapshot = Self.snapshot(analysis: importedAnalysis)
        let provider = ImportSupersedingRehydrationProvider(
            importedSnapshot: importedSnapshot,
            gate: gate
        )
        let store = WorkspaceStore(
            workspaceName: "Old",
            snapshot: Self.snapshot(analysis: oldAnalysis),
            engine: provider,
            autosaveScheduler: nil
        )

        let firstPass = Task { @MainActor in
            await store.rehydrateLoadedImagesSynchronouslyForTesting()
        }
        await Task.detached { gate.waitUntilFirstCallEntered() }.value
        await store.importBinary(url: URL(fileURLWithPath: "/tmp/imported"))

        XCTAssertEqual(store.snapshot.functions.first?.name, "imported")
        gate.releaseFirstCall()
        await Task.detached { gate.waitUntilFirstCallFinished() }.value
        await firstPass.value
        XCTAssertTrue(gate.firstCallObservedCancellation)
        XCTAssertEqual(store.snapshot.functions.first?.name, "imported")
    }

    func testDatabaseRoundTripRehydrationMatchesFreshAnalysis() async throws {
        let systemBinaryURL = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.isReadableFile(atPath: systemBinaryURL.path) else {
            throw XCTSkip("/bin/ls not readable")
        }
        let engine = AnalysisEngine()
        var freshSnapshot = try engine.analyze(
            url: systemBinaryURL,
            requestedSliceIndex: nil,
            overrides: [:],
            cancellation: .never
        )
        freshSnapshot.mutateAnalysis(in: freshSnapshot.primarySlot) {
            $0.sourceLines = [SourceLineEntry(
                address: $0.instructions.first?.address ?? 0,
                file: "/src/rehydration-db-oracle.c",
                line: 77,
                column: 3,
                endSequence: false
            )]
        }
        let fresh = try XCTUnwrap(freshSnapshot.analysis(in: freshSnapshot.primarySlot))
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        let workspace = try database.saveSnapshot(
            workspaceName: "DB oracle",
            snapshot: freshSnapshot
        )
        let reopenedSnapshot = try XCTUnwrap(database.loadSnapshot(
            workspaceID: try XCTUnwrap(workspace.id)
        ))
        let persisted = try XCTUnwrap(reopenedSnapshot.analysis(in: reopenedSnapshot.primarySlot))
        XCTAssertTrue(persisted.sections.isEmpty)
        XCTAssertNil(persisted.machOMetadata)
        let store = WorkspaceStore(
            workspaceName: "DB oracle", snapshot: reopenedSnapshot,
            engine: engine, autosaveScheduler: nil
        )

        await store.rehydrateLoadedImagesSynchronouslyForTesting()

        let rehydrated = try XCTUnwrap(store.snapshot.analysis(in: store.snapshot.primarySlot))
        assertRehydrated(rehydrated, matches: fresh, preserving: persisted)
        XCTAssertFalse(store.isDirty)
    }

    func testPackageRoundTripRehydrationMatchesFreshAnalysis() async throws {
        let systemBinaryURL = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.isReadableFile(atPath: systemBinaryURL.path) else {
            throw XCTSkip("/bin/ls not readable")
        }
        let engine = AnalysisEngine()
        var freshSnapshot = try engine.analyze(
            url: systemBinaryURL,
            requestedSliceIndex: nil,
            overrides: [:],
            cancellation: .never
        )
        freshSnapshot.mutateAnalysis(in: freshSnapshot.primarySlot) {
            $0.sourceLines = [SourceLineEntry(
                address: $0.instructions.first?.address ?? 0,
                file: "/src/rehydration-package-oracle.c",
                line: 88,
                column: 5,
                endSequence: false
            )]
        }
        let fresh = try XCTUnwrap(freshSnapshot.analysis(in: freshSnapshot.primarySlot))
        let sourceStore = WorkspaceStore(
            workspaceName: "Package oracle", snapshot: freshSnapshot,
            engine: engine, autosaveScheduler: nil
        )
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RehydrationOracle-\(UUID().uuidString)")
            .appendingPathExtension(MacScopeDocumentPackage.fileExtension)
        defer { try? FileManager.default.removeItem(at: packageURL) }
        try sourceStore.saveWorkspacePackage(to: packageURL, using: database)

        let reopenedStore = try WorkspaceStore.restoredPackage(from: packageURL, engine: engine)
        let persisted = try XCTUnwrap(
            reopenedStore.snapshot.analysis(in: reopenedStore.snapshot.primarySlot)
        )
        XCTAssertTrue(persisted.sections.isEmpty)
        XCTAssertNil(persisted.machOMetadata)

        await reopenedStore.rehydrateLoadedImagesSynchronouslyForTesting()

        let rehydrated = try XCTUnwrap(
            reopenedStore.snapshot.analysis(in: reopenedStore.snapshot.primarySlot)
        )
        assertRehydrated(rehydrated, matches: fresh, preserving: persisted)
        XCTAssertFalse(reopenedStore.isDirty)
    }

    func testDatabaseReopenWithEmptyImageBytesRemainsDerivedEmpty() async throws {
        var analysis = ImageAnalysis()
        analysis.functions = [FunctionSummary(
            id: UUID(), name: "legacy", startAddress: 0x1000,
            endAddress: 0x1010, confidence: 1
        )]
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspace = try database.saveSnapshot(
            workspaceName: "No attachment",
            snapshot: Self.snapshot(analysis: analysis)
        )
        let reopened = try XCTUnwrap(database.loadSnapshot(
            workspaceID: try XCTUnwrap(workspace.id)
        ))
        let store = WorkspaceStore(
            workspaceName: "No attachment", snapshot: reopened,
            engine: AnalysisEngine(), autosaveScheduler: nil
        )

        await store.rehydrateLoadedImagesSynchronouslyForTesting()

        let result = try XCTUnwrap(store.snapshot.analysis(in: .primary))
        XCTAssertTrue(result.imageBytes.isEmpty)
        XCTAssertTrue(result.sections.isEmpty)
        XCTAssertNil(result.machOMetadata)
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertEqual(result.functions, analysis.functions)
    }

    func testCorruptPersistedBytesRemainDerivedEmptyAndAddProblem() async throws {
        var analysis = ImageAnalysis()
        analysis.imageBytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspace = try database.saveSnapshot(
            workspaceName: "Corrupt",
            snapshot: Self.snapshot(analysis: analysis)
        )
        let reopened = try XCTUnwrap(database.loadSnapshot(
            workspaceID: try XCTUnwrap(workspace.id)
        ))
        let store = WorkspaceStore(
            workspaceName: "Corrupt",
            snapshot: reopened,
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )

        await store.rehydrateLoadedImagesSynchronouslyForTesting()

        let result = try XCTUnwrap(store.snapshot.analysis(in: .primary))
        XCTAssertTrue(result.sections.isEmpty)
        XCTAssertNil(result.machOMetadata)
        let diagnostic = try XCTUnwrap(result.diagnostics.first)
        XCTAssertEqual(diagnostic.severity, .error)
        XCTAssertEqual(diagnostic.kind, .loaderTruncation)
        XCTAssertTrue(diagnostic.message.localizedCaseInsensitiveContains("restore derived analysis"))
        XCTAssertFalse(store.isDirty)
    }

    func testProblemsProjectionSurfacesFocusedSecondaryRehydrationFailure() async throws {
        let secondarySlot = ImageSlot(rawValue: 1)
        var primary = ImageAnalysis()
        primary.sections = [SectionSummary(
            id: UUID(), name: "already_loaded", address: 0x1000, size: 4,
            fileOffset: 0, isExecutable: true
        )]
        var secondary = ImageAnalysis()
        secondary.imageBytes = Data([0xBA, 0xD0])
        let provider = ScriptedRehydrationProvider { _, _, _, _ in
            throw RehydrationStoreTestError.scriptedFailure
        }
        let store = WorkspaceStore(
            workspaceName: "Focused Problems",
            snapshot: WorkspaceSnapshot(
                binaries: [
                    Self.binary(slot: .primary, name: "primary"),
                    Self.binary(slot: secondarySlot, name: "secondary"),
                ],
                analysisBySlot: [.primary: primary, secondarySlot: secondary]
            ),
            engine: provider,
            autosaveScheduler: nil
        )
        store.focusImage(secondarySlot)

        await store.rehydrateLoadedImagesSynchronouslyForTesting()

        let secondaryProblems = try XCTUnwrap(
            store.snapshot.analysis(in: secondarySlot)?.diagnostics
        )
        XCTAssertEqual(secondaryProblems.count, 1)
        XCTAssertEqual(store.diagnostics, secondaryProblems)
    }

    private func assertRehydrated(
        _ actual: ImageAnalysis,
        matches fresh: ImageAnalysis,
        preserving persisted: ImageAnalysis,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            actual.sections.map(Self.sectionKey),
            fresh.sections.map(Self.sectionKey),
            file: file,
            line: line
        )
        XCTAssertEqual(actual.relocations, fresh.relocations, file: file, line: line)
        XCTAssertEqual(actual.machOMetadata, fresh.machOMetadata, file: file, line: line)
        XCTAssertEqual(actual.jumpTables, fresh.jumpTables, file: file, line: line)
        XCTAssertEqual(actual.objcSelectors, fresh.objcSelectors, file: file, line: line)
        XCTAssertEqual(actual.objcClasses, fresh.objcClasses, file: file, line: line)
        XCTAssertEqual(actual.objcCategories, fresh.objcCategories, file: file, line: line)
        XCTAssertEqual(actual.swiftTypes, fresh.swiftTypes, file: file, line: line)
        XCTAssertEqual(actual.swiftConformances, fresh.swiftConformances, file: file, line: line)
        XCTAssertEqual(actual.diagnostics, fresh.diagnostics, file: file, line: line)

        XCTAssertEqual(actual.functions, persisted.functions, file: file, line: line)
        XCTAssertEqual(actual.symbols, persisted.symbols, file: file, line: line)
        XCTAssertEqual(actual.imports, persisted.imports, file: file, line: line)
        XCTAssertEqual(actual.indirectSymbols, persisted.indirectSymbols, file: file, line: line)
        XCTAssertEqual(actual.exports, persisted.exports, file: file, line: line)
        XCTAssertEqual(actual.stringLiterals, persisted.stringLiterals, file: file, line: line)
        XCTAssertEqual(actual.instructions, persisted.instructions, file: file, line: line)
        XCTAssertEqual(actual.xrefs, persisted.xrefs, file: file, line: line)
        XCTAssertEqual(actual.basicBlocks, persisted.basicBlocks, file: file, line: line)
        XCTAssertEqual(actual.controlFlowEdges, persisted.controlFlowEdges, file: file, line: line)
        XCTAssertEqual(actual.sourceLines, persisted.sourceLines, file: file, line: line)
        XCTAssertEqual(actual.hexBytes, persisted.hexBytes, file: file, line: line)
        XCTAssertEqual(actual.imageBytes, persisted.imageBytes, file: file, line: line)

        XCTAssertEqual(persisted.functions, fresh.functions, file: file, line: line)
        XCTAssertEqual(persisted.symbols, fresh.symbols, file: file, line: line)
        XCTAssertEqual(persisted.imports, fresh.imports, file: file, line: line)
        XCTAssertEqual(persisted.indirectSymbols, fresh.indirectSymbols, file: file, line: line)
        XCTAssertEqual(persisted.exports, fresh.exports, file: file, line: line)
        XCTAssertEqual(persisted.stringLiterals, fresh.stringLiterals, file: file, line: line)
        XCTAssertEqual(persisted.instructions, fresh.instructions, file: file, line: line)
        XCTAssertEqual(
            persisted.xrefs.map(Self.xrefKey).sorted(),
            fresh.xrefs.map(Self.xrefKey).sorted(),
            file: file,
            line: line
        )
        XCTAssertEqual(persisted.basicBlocks, fresh.basicBlocks, file: file, line: line)
        XCTAssertEqual(
            persisted.controlFlowEdges.map(Self.controlFlowEdgeKey).sorted(),
            fresh.controlFlowEdges.map(Self.controlFlowEdgeKey).sorted(),
            file: file,
            line: line
        )
        XCTAssertEqual(persisted.sourceLines, fresh.sourceLines, file: file, line: line)
        XCTAssertEqual(persisted.hexBytes, fresh.hexBytes, file: file, line: line)
        XCTAssertEqual(persisted.imageBytes, fresh.imageBytes, file: file, line: line)
    }

    private static func sectionKey(_ section: SectionSummary) -> String {
        "\(section.name)|\(section.address)|\(section.size)|\(section.fileOffset)|"
            + "\(section.isExecutable)|\(section.isZeroFill)|\(String(describing: section.fileSize))"
    }

    private static func xrefKey(_ xref: XRef) -> String {
        "\(xref.from)|\(xref.to)|\(xref.kind)"
    }

    private static func controlFlowEdgeKey(_ edge: ControlFlowEdge) -> String {
        "\(edge.from)|\(edge.to)|\(edge.kind)"
    }

    private enum RehydrationReanalysisCompletionOrder {
        case rehydrationCompletesLast
        case reanalysisCompletesLast
    }

    private func assertStructuralReanalysisWins(
        over completionOrder: RehydrationReanalysisCompletionOrder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let address: UInt64 = 0x5C00
        let persistedFunction = FunctionSummary(
            id: UUID(), name: "persisted_before_structural_edit", startAddress: address,
            endAddress: address + 4, confidence: 1
        )
        var persisted = ImageAnalysis()
        persisted.imageBytes = Data([0x5C, 0x01])
        persisted.functions = [persistedFunction]
        persisted.instructions = [InstructionRow(
            address: address, bytes: "00 00 00 00", mnemonic: "persisted_nop", operands: "",
            hasBreakpoint: false, comment: nil
        )]
        XCTAssertTrue(persisted.sections.isEmpty, "fixture must be eligible for rehydration", file: file, line: line)

        let rehydratedSection = SectionSummary(
            id: UUID(), name: "loader_rehydrated", address: address, size: 0x20,
            fileOffset: 0, isExecutable: true
        )
        var structurallyReanalyzed = persisted
        structurallyReanalyzed.sections = [SectionSummary(
            id: UUID(), name: "structurally_reanalyzed", address: address, size: 0x20,
            fileOffset: 0, isExecutable: true
        )]
        structurallyReanalyzed.functions = [FunctionSummary(
            id: UUID(), name: "structural_edit_result", startAddress: address,
            endAddress: address + 8, confidence: 1
        )]
        structurallyReanalyzed.instructions = [InstructionRow(
            address: address, bytes: "c0 03 5f d6", mnemonic: "reanalyzed_ret", operands: "",
            hasBreakpoint: false, comment: nil
        )]

        let supersededInitialGate = RehydrationCallGate()
        let replacementRehydrationGate = RehydrationCallGate()
        let structuralReanalysisGate = AsyncAnalysisCallGate()
        let provider = RehydrationReanalysisRaceProvider(
            supersededInitialGate: supersededInitialGate,
            replacementRehydrationGate: replacementRehydrationGate,
            structuralReanalysisGate: structuralReanalysisGate,
            rehydratedSection: rehydratedSection,
            structurallyReanalyzedSnapshot: Self.snapshot(analysis: structurallyReanalyzed)
        )
        let store = WorkspaceStore(
            workspaceName: "Rehydration versus structural reanalysis",
            snapshot: Self.snapshot(analysis: persisted),
            engine: provider,
            autosaveScheduler: nil
        )

        store.rehydrateLoadedImages()
        await Task.detached { supersededInitialGate.waitUntilFirstCallEntered() }.value

        // The edit cancels pass 1, schedules replacement rehydration from the post-edit snapshot,
        // and independently starts structural reanalysis for the same image slot.
        store.setIsData(address, true)
        await structuralReanalysisGate.waitUntilEntered()
        await Task.detached { replacementRehydrationGate.waitUntilFirstCallEntered() }.value

        switch completionOrder {
        case .rehydrationCompletesLast:
            await structuralReanalysisGate.release()
            await store.awaitPendingReanalysis()
            XCTAssertEqual(
                store.snapshot.analysis(in: .primary)?.functions.first?.name,
                "structural_edit_result",
                file: file,
                line: line
            )

            replacementRehydrationGate.releaseFirstCall()
            await store.awaitCurrentRehydrationForTesting()
            await Task.detached { replacementRehydrationGate.waitUntilFirstCallFinished() }.value

        case .reanalysisCompletesLast:
            replacementRehydrationGate.releaseFirstCall()
            await store.awaitCurrentRehydrationForTesting()
            await Task.detached { replacementRehydrationGate.waitUntilFirstCallFinished() }.value
            XCTAssertEqual(
                store.snapshot.analysis(in: .primary)?.functions.first?.name,
                persistedFunction.name,
                file: file,
                line: line
            )

            await structuralReanalysisGate.release()
            await store.awaitPendingReanalysis()
        }

        supersededInitialGate.releaseFirstCall()
        await Task.detached { supersededInitialGate.waitUntilFirstCallFinished() }.value

        let finalAnalysis = store.snapshot.analysis(in: .primary)
        XCTAssertEqual(
            finalAnalysis?.functions.first?.name,
            "structural_edit_result",
            "loader-only rehydration must not restore structural products captured before the edit",
            file: file,
            line: line
        )
        XCTAssertEqual(finalAnalysis?.instructions.first?.mnemonic, "reanalyzed_ret", file: file, line: line)
        XCTAssertEqual(
            store.snapshot.addressOverrides[ImageAddress(slot: .primary, address: address)]?.isData,
            true,
            file: file,
            line: line
        )
        XCTAssertEqual(provider.rehydrateCallCount, 2, file: file, line: line)
        XCTAssertTrue(supersededInitialGate.firstCallObservedCancellation, file: file, line: line)
    }

    private static func snapshot(analysis: ImageAnalysis, slot: ImageSlot = .primary) -> WorkspaceSnapshot {
        let binary = binary(slot: slot, name: "fixture")
        return WorkspaceSnapshot(binaries: [binary], analysisBySlot: [slot: analysis])
    }

    private static func binary(slot: ImageSlot, name: String) -> BinaryImage {
        BinaryImage(
            id: UUID(), name: name, path: "/tmp/\(name)",
            kind: "fixture binary", architecture: "arm64", slot: slot
        )
    }

    private func restoredPendingSelectionStore(
        analysis: ImageAnalysis,
        selectedAddress: UInt64,
        engine: any AnalysisProviding
    ) throws -> WorkspaceStore {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let state = try database.createWorkspaceState(
            workspaceName: "Pending mapped selection",
            snapshot: Self.snapshot(analysis: analysis),
            selectedSidebarItemID: nil,
            selectedAddress: selectedAddress,
            selectedTool: .project,
            editorMode: .hex,
            isInspectorPresented: true,
            sidebarSearchText: ""
        )
        return try XCTUnwrap(WorkspaceStore.restored(
            workspaceID: try XCTUnwrap(state.workspace.id),
            from: database,
            engine: engine
        ))
    }
}

private enum RehydrationStoreTestError: Error {
    case unexpectedAnalysis
    case scriptedFailure
}

/// A narrow provider double: the store tests exercise orchestration and splicing, while the
/// end-to-end tests below use `AnalysisEngine` to prove real loader behavior.
private final class ScriptedRehydrationProvider: AnalysisProviding, @unchecked Sendable {
    typealias RehydrationScript = @Sendable (
        Data, Int?, ImageAnalysis, AnalysisCancellationToken
    ) throws -> ImageAnalysis

    private let script: RehydrationScript
    private let lock = NSLock()
    private var callCount = 0

    init(script: @escaping RehydrationScript) {
        self.script = script
    }

    var rehydrateCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        throw RehydrationStoreTestError.unexpectedAnalysis
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        throw RehydrationStoreTestError.unexpectedAnalysis
    }

    func rehydrate(
        imageBytes: Data,
        requestedSliceIndex: Int?,
        preserving persisted: ImageAnalysis,
        cancellation: AnalysisCancellationToken
    ) throws -> ImageAnalysis {
        lock.lock()
        callCount += 1
        lock.unlock()
        return try script(imageBytes, requestedSliceIndex, persisted, cancellation)
    }
}

private final class ImportSupersedingRehydrationProvider: AnalysisProviding, @unchecked Sendable {
    private let importedSnapshot: WorkspaceSnapshot
    private let gate: RehydrationCallGate

    init(importedSnapshot: WorkspaceSnapshot, gate: RehydrationCallGate) {
        self.importedSnapshot = importedSnapshot
        self.gate = gate
    }

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        throw RehydrationStoreTestError.unexpectedAnalysis
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        importedSnapshot
    }

    func rehydrate(
        imageBytes: Data,
        requestedSliceIndex: Int?,
        preserving persisted: ImageAnalysis,
        cancellation: AnalysisCancellationToken
    ) throws -> ImageAnalysis {
        gate.enterAndWait()
        gate.recordCancellation(cancellation.isCancelled)
        var stale = persisted
        stale.sections = [SectionSummary(
            id: UUID(), name: "stale", address: 0x1000, size: 0x10,
            fileOffset: 0, isExecutable: true
        )]
        gate.finishFirstCall()
        return stale
    }
}

/// First rehydration blocks so an import can cancel it. The import always fails; the restarted
/// unchanged-workspace pass returns immediately with the exact mapping used to validate selection.
private final class FailedImportRestartRehydrationProvider: AnalysisProviding, @unchecked Sendable {
    private let gate: RehydrationCallGate
    private let mappedSection: SectionSummary
    private let lock = NSLock()
    private var callCount = 0

    init(gate: RehydrationCallGate, mappedSection: SectionSummary) {
        self.gate = gate
        self.mappedSection = mappedSection
    }

    var rehydrateCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        throw RehydrationStoreTestError.unexpectedAnalysis
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        throw RehydrationStoreTestError.scriptedFailure
    }

    func rehydrate(
        imageBytes: Data,
        requestedSliceIndex: Int?,
        preserving persisted: ImageAnalysis,
        cancellation: AnalysisCancellationToken
    ) throws -> ImageAnalysis {
        lock.lock()
        callCount += 1
        let currentCall = callCount
        lock.unlock()

        if currentCall == 1 {
            gate.enterAndWait()
            gate.recordCancellation(cancellation.isCancelled)
            gate.finishFirstCall()
        }
        var result = persisted
        result.sections = [mappedSection]
        return result
    }
}

/// Exercises every operation that temporarily supersedes restore-time work while retaining the
/// installed workspace. Only the first pass blocks; a production restart resolves immediately from
/// the current snapshot so tests can distinguish an automatic restart from an abandoned pass.
private final class RehydrationLifecycleProvider: AnalysisProviding, @unchecked Sendable {
    enum OpenResult {
        case failure
        case success(WorkspaceSnapshot)
    }

    private let gate: RehydrationCallGate
    private let mappedSection: SectionSummary
    private let openResult: OpenResult
    private let lock = NSLock()
    private var callCount = 0

    init(
        gate: RehydrationCallGate,
        mappedSection: SectionSummary,
        openResult: OpenResult
    ) {
        self.gate = gate
        self.mappedSection = mappedSection
        self.openResult = openResult
    }

    var rehydrateCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        throw RehydrationStoreTestError.unexpectedAnalysis
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        switch openResult {
        case .failure:
            throw RehydrationStoreTestError.scriptedFailure
        case let .success(snapshot):
            return snapshot
        }
    }

    func rehydrate(
        imageBytes: Data,
        requestedSliceIndex: Int?,
        preserving persisted: ImageAnalysis,
        cancellation: AnalysisCancellationToken
    ) throws -> ImageAnalysis {
        lock.lock()
        callCount += 1
        let currentCall = callCount
        lock.unlock()

        if currentCall == 1 {
            gate.enterAndWait()
            gate.recordCancellation(cancellation.isCancelled)
            gate.finishFirstCall()
        }
        var result = persisted
        result.sections = [mappedSection]
        return result
    }
}

/// Forces loader-only rehydration and structural reanalysis for one eligible image to overlap.
/// Call 1 is the restore pass cancelled by the edit; call 2 is the post-mutation replacement whose
/// completion is ordered independently from `openBinary` so both last-writer permutations are exact.
private final class RehydrationReanalysisRaceProvider: AnalysisProviding, @unchecked Sendable {
    private let supersededInitialGate: RehydrationCallGate
    private let replacementRehydrationGate: RehydrationCallGate
    private let structuralReanalysisGate: AsyncAnalysisCallGate
    private let rehydratedSection: SectionSummary
    private let structurallyReanalyzedSnapshot: WorkspaceSnapshot
    private let lock = NSLock()
    private var callCount = 0

    init(
        supersededInitialGate: RehydrationCallGate,
        replacementRehydrationGate: RehydrationCallGate,
        structuralReanalysisGate: AsyncAnalysisCallGate,
        rehydratedSection: SectionSummary,
        structurallyReanalyzedSnapshot: WorkspaceSnapshot
    ) {
        self.supersededInitialGate = supersededInitialGate
        self.replacementRehydrationGate = replacementRehydrationGate
        self.structuralReanalysisGate = structuralReanalysisGate
        self.rehydratedSection = rehydratedSection
        self.structurallyReanalyzedSnapshot = structurallyReanalyzedSnapshot
    }

    var rehydrateCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        throw RehydrationStoreTestError.unexpectedAnalysis
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        await structuralReanalysisGate.enterAndWait()
        return structurallyReanalyzedSnapshot
    }

    func rehydrate(
        imageBytes: Data,
        requestedSliceIndex: Int?,
        preserving persisted: ImageAnalysis,
        cancellation: AnalysisCancellationToken
    ) throws -> ImageAnalysis {
        lock.lock()
        callCount += 1
        let currentCall = callCount
        lock.unlock()

        let gate: RehydrationCallGate
        switch currentCall {
        case 1:
            gate = supersededInitialGate
        case 2:
            gate = replacementRehydrationGate
        default:
            throw RehydrationStoreTestError.unexpectedAnalysis
        }

        gate.enterAndWait()
        gate.recordCancellation(cancellation.isCancelled)
        var result = persisted
        result.sections = [rehydratedSection]
        gate.finishFirstCall()
        return result
    }
}

/// Blocks two successive restore passes so the await-only test can replace pass 1 while a waiter
/// is suspended on it, then prove that waiter follows the still-running pass 2.
private final class TwoPassBlockingRehydrationProvider: AnalysisProviding, @unchecked Sendable {
    private let supersededGate: RehydrationCallGate
    private let replacementGate: RehydrationCallGate
    private let lock = NSLock()
    private var callCount = 0

    init(supersededGate: RehydrationCallGate, replacementGate: RehydrationCallGate) {
        self.supersededGate = supersededGate
        self.replacementGate = replacementGate
    }

    var rehydrateCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        throw RehydrationStoreTestError.unexpectedAnalysis
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        throw RehydrationStoreTestError.unexpectedAnalysis
    }

    func rehydrate(
        imageBytes: Data,
        requestedSliceIndex: Int?,
        preserving persisted: ImageAnalysis,
        cancellation: AnalysisCancellationToken
    ) throws -> ImageAnalysis {
        lock.lock()
        callCount += 1
        let currentCall = callCount
        lock.unlock()

        let gate: RehydrationCallGate
        switch currentCall {
        case 1: gate = supersededGate
        case 2: gate = replacementGate
        default: throw RehydrationStoreTestError.unexpectedAnalysis
        }
        gate.enterAndWait()
        gate.recordCancellation(cancellation.isCancelled)
        var result = persisted
        result.sections = [SectionSummary(
            id: UUID(), name: "pass_\(currentCall)", address: 0x5D00, size: 0x20,
            fileOffset: 0, isExecutable: false
        )]
        gate.finishFirstCall()
        return result
    }
}

@MainActor
private final class RehydrationAwaitProbe {
    var didStart = false
    var didReturn = false
}

/// Suspends one interactive structural reanalysis without blocking the cooperative executor.
private actor AsyncAnalysisCallGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

/// The structural edit and replacement import share `openBinary`; URL identity makes the former
/// block and the latter fail so the test proves import failure does not retire unrelated work.
private final class FailedImportReanalysisProvider: AnalysisProviding, @unchecked Sendable {
    private let gate: AsyncAnalysisCallGate
    private let reanalyzedSnapshot: WorkspaceSnapshot
    private let lock = NSLock()
    private var observedCancellation = false

    init(gate: AsyncAnalysisCallGate, reanalyzedSnapshot: WorkspaceSnapshot) {
        self.gate = gate
        self.reanalyzedSnapshot = reanalyzedSnapshot
    }

    var reanalysisObservedCancellation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedCancellation
    }

    private func recordReanalysisCancellation(_ value: Bool) {
        lock.lock()
        observedCancellation = value
        lock.unlock()
    }

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        throw RehydrationStoreTestError.unexpectedAnalysis
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        if url.lastPathComponent == "failing-import" {
            throw RehydrationStoreTestError.scriptedFailure
        }
        await gate.enterAndWait()
        recordReanalysisCancellation(Task.isCancelled || cancellation.isCancelled)
        return reanalyzedSnapshot
    }
}

/// A deterministic gate for a synchronous provider call. The first rehydrate blocks until the
/// test releases it, allowing cancellation, restore supersession, and deinitialization to race in a
/// controlled way without sleeping.
private final class RehydrationCallGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var observedCancellation = false

    func enterAndWait() {
        entered.signal()
        release.wait()
    }

    func waitUntilFirstCallEntered() { entered.wait() }
    func releaseFirstCall() { release.signal() }
    func finishFirstCall() { finished.signal() }
    func waitUntilFirstCallFinished() { finished.wait() }

    func recordCancellation(_ value: Bool) {
        lock.lock()
        observedCancellation = value
        lock.unlock()
    }

    var firstCallObservedCancellation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedCancellation
    }
}
