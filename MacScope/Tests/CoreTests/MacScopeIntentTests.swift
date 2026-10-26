import AppIntents
import Foundation
import XCTest
@testable import MacScope

@MainActor
final class MacScopeIntentTests: XCTestCase {
    func testIntentWaitsForImportAndPreservesOccupiedExplicitWindow() async throws {
        let h = makeHarness(gated: true)
        let priorRouter = WorkspaceApplicationOpenRouter.installed
        let priorStore = ScriptingHost.shared.activeStore
        defer {
            WorkspaceApplicationOpenRouter.installed = priorRouter
            ScriptingHost.shared.activeStore = priorStore
            h.loader.release()
        }
        let occupied = WorkspaceStore.bootstrapForPreviewFixture()
        let occupiedID = WorkspaceWindowID.fresh()
        h.registry.adopt(occupied, for: occupiedID)
        ScriptingHost.shared.activeStore = occupied
        WorkspaceApplicationOpenRouter.installed = h.router
        var opened: [WorkspaceWindowID] = []
        h.router.installWindowPresenter { opened.append($0) }
        var completed = false
        var intent = OpenBinaryIntent()
        intent.file = IntentFile(fileURL: Self.url)
        let invocation = Task { @MainActor in
            defer { completed = true }
            _ = try await intent.perform()
        }
        await Task.detached { h.loader.waitUntilEntered() }.value
        XCTAssertFalse(completed, "window admission is not import success")
        XCTAssertEqual(opened.count, 1)
        XCTAssertNotEqual(opened.first, occupiedID)
        XCTAssertTrue(h.registry.storeIfPresent(for: occupiedID) === occupied)
        h.loader.release()
        try await invocation.value
        guard case .completed(let binaryID) = h.store.binaryOpenState?.phase else {
            return XCTFail("Intent must acknowledge installed image identity")
        }
        XCTAssertEqual(h.store.snapshot.binaries.first?.id, binaryID)
    }

    func testColdIngressWaitsForAppPresenterThenCompletes() async throws {
        let h = makeHarness()
        let prior = WorkspaceApplicationOpenRouter.installed
        defer { WorkspaceApplicationOpenRouter.installed = prior }
        WorkspaceApplicationOpenRouter.installed = nil
        var presented = false
        let invocation = Task { @MainActor in
            try await WorkspaceApplicationOpenRouter.openIntentBinary(Self.url, preferredStore: nil,
                                                                       startupTimeout: .seconds(1))
        }
        await Task.yield()
        XCTAssertTrue(h.store.snapshot.binaries.isEmpty)
        WorkspaceApplicationOpenRouter.installed = h.router
        h.router.installWindowPresenter { _ in presented = true }
        let binaryID = try await invocation.value
        XCTAssertTrue(presented)
        XCTAssertEqual(h.store.snapshot.binaries.first?.id, binaryID)
    }

    func testReusableExplicitWindowRetainsItsSessionAndNativeOwner() async throws {
        let h = makeHarness()
        let owner = WorkspaceWindowID.fresh()
        h.registry.adopt(h.store, for: owner)
        let session = try XCTUnwrap(h.registry.documentSessionIfPresent(for: owner))
        var presented: [WorkspaceWindowID] = []
        h.router.installWindowPresenter { presented.append($0) }
        _ = try await h.router.openBinaryAcknowledged(Self.url, preferredStore: h.store)
        XCTAssertEqual(presented, [owner])
        XCTAssertTrue(h.registry.documentSessionIfPresent(for: owner) === session)
        XCTAssertEqual(h.registry.count, 1)
    }

    func testInstalledBytesDoNotAcknowledgeBeforeNativeWindowMounts() async throws {
        let nativeWindow = NSObject()
        var mounted = false
        let h = makeHarness(windowIdentity: { _ in mounted ? ObjectIdentifier(nativeWindow) : nil })
        h.router.installWindowPresenter { _ in }
        var completed = false
        let invocation = Task { @MainActor in
            defer { completed = true }
            return try await h.router.openBinaryAcknowledged(Self.url, timeout: .seconds(2))
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while h.store.binaryOpenState?.phase.isTerminal != true {
            guard clock.now < deadline else { throw WorkspaceApplicationOpenError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(completed)
        mounted = true
        let installed = try await invocation.value
        XCTAssertEqual(h.store.snapshot.binaries.first?.id, installed)
    }

    func testNativeWindowReplacementRejectsSameSessionAcknowledgement() async throws {
        let firstWindow = NSObject()
        let replacementWindow = NSObject()
        var nativeOwner = ObjectIdentifier(firstWindow)
        let h = makeHarness(choosing: true, windowIdentity: { _ in nativeOwner })
        h.router.installWindowPresenter { _ in }
        let invocation = Task { @MainActor in try await h.router.openBinaryAcknowledged(Self.url) }
        try await waitForChoice(h.store)
        nativeOwner = ObjectIdentifier(replacementWindow)
        do { _ = try await invocation.value; XCTFail("A replacement native window is not the requesting window") }
        catch WorkspaceApplicationOpenError.displaced { }
        XCTAssertEqual(h.store.binaryOpenState?.phase, .cancelled)
    }

    func testSliceCancellationAndConfirmationAcknowledgeExactTicket() async throws {
        // Explicit selections intentionally reopen through BinaryLoaderRouter, rather than
        // the engine's automatic-selection injected loader. Exercise real universal bytes.
        let fixture = MachOFixture.makeUniversalDualExecutable()
        let directory = TestWorkRoot.scratch
            .appendingPathComponent("intent-slice-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("IntentUniversalFixture")
        try fixture.bytes.write(to: url)
        for confirm in [false, true] {
            let h = makeHarness(realInspection: true)
            h.router.installWindowPresenter { _ in }
            let invocation = Task { @MainActor in try await h.router.openBinaryAcknowledged(url) }
            try await waitForChoice(h.store)
            XCTAssertTrue(h.store.snapshot.binaries.isEmpty)
            let ticket = try XCTUnwrap(h.store.binaryOpenState?.id)
            if confirm {
                let request = try XCTUnwrap(h.store.loaderOptionsRequest)
                let selectedSlice = try XCTUnwrap(request.model.binaryLoadSelectionForLoad.requestedMachOSliceIndex)
                h.store.confirmLoaderOptions(request)
                let binaryID = try await invocation.value
                XCTAssertEqual(h.store.binaryOpenState,
                               WorkspaceBinaryOpenState(id: ticket, phase: .completed(binaryID)))
                let installed = try XCTUnwrap(h.store.snapshot.binaries.first)
                XCTAssertEqual(installed.id, binaryID)
                XCTAssertEqual(installed.selectedSliceIndex, selectedSlice)
                XCTAssertEqual(installed.artifactIntegrityState, .verified)
                XCTAssertEqual(installed.path, url.path)
            } else {
                h.store.cancelLoaderOptions()
                do { _ = try await invocation.value; XCTFail("Cancelled slice cannot succeed") }
                catch is CancellationError { }
            }
        }
    }

    func testSupersessionRejectsOldTicketWithoutCancellingNewSliceRequest() async throws {
        let h = makeHarness(choosing: true)
        h.router.installWindowPresenter { _ in }
        let invocation = Task { @MainActor in try await h.router.openBinaryAcknowledged(Self.url) }
        try await waitForChoice(h.store)
        let stale = try XCTUnwrap(h.store.loaderOptionsRequest)
        let replacement = h.store.beginImport(url: Self.url)
        try await waitForChoice(h.store)
        h.store.confirmLoaderOptions(stale)
        do { _ = try await invocation.value; XCTFail("Replacement is not old request success") }
        catch WorkspaceApplicationOpenError.displaced { }
        XCTAssertEqual(h.store.binaryOpenState?.id, replacement)
        XCTAssertEqual(h.store.binaryOpenState?.phase, .choosing)
        h.store.cancelBinaryOpen(replacement)
    }

    func testTimeoutAndCallerCancellationCancelExactPendingChoice() async throws {
        for callerCancels in [false, true] {
            let h = makeHarness(choosing: true)
            h.router.installWindowPresenter { _ in }
            let invocation = Task { @MainActor in
                try await h.router.openBinaryAcknowledged(Self.url,
                    timeout: callerCancels ? .seconds(2) : .seconds(1))
            }
            try await waitForChoice(h.store)
            if callerCancels { invocation.cancel() }
            do { _ = try await invocation.value; XCTFail("Pending choice cannot succeed") }
            catch is CancellationError { XCTAssertTrue(callerCancels) }
            catch WorkspaceApplicationOpenError.timedOut { XCTAssertFalse(callerCancels) }
            XCTAssertEqual(h.store.binaryOpenState?.phase, .cancelled)
            XCTAssertNil(h.store.loaderOptionsRequest)
            XCTAssertTrue(h.store.snapshot.binaries.isEmpty)
        }
    }

    func testClosedSessionAndLoaderFailureNeverReportSuccess() async throws {
        for closeSession in [true, false] {
            let h = makeHarness(choosing: closeSession, fails: !closeSession)
            var owner: WorkspaceWindowID?
            h.router.installWindowPresenter { owner = $0 }
            let invocation = Task { @MainActor in try await h.router.openBinaryAcknowledged(Self.url) }
            if closeSession {
                try await waitForChoice(h.store)
                h.registry.documentSessionIfPresent(for: try XCTUnwrap(owner))?.close()
            }
            do { _ = try await invocation.value; XCTFail("Retired/failed request cannot succeed") }
            catch WorkspaceApplicationOpenError.displaced { XCTAssertTrue(closeSession) }
            catch WorkspaceApplicationOpenError.failed { XCTAssertFalse(closeSession) }
            XCTAssertTrue(h.store.snapshot.binaries.isEmpty)
        }
    }

    func testNeverMountedTimeoutAndCancellationRetireExactEmptyEntry() async throws {
        for callerCancels in [false, true] {
            let h = makeHarness(choosing: true, windowIdentity: { _ in nil })
            var owner: WorkspaceWindowID?
            h.router.installWindowPresenter { owner = $0 }
            let invocation = Task { @MainActor in
                try await h.router.openBinaryAcknowledged(Self.url,
                    timeout: callerCancels ? .seconds(2) : .milliseconds(100))
            }
            try await waitForChoice(h.store)
            let id = try XCTUnwrap(owner)
            let session = try XCTUnwrap(h.registry.documentSessionIfPresent(for: id))
            if callerCancels { invocation.cancel() }
            do { _ = try await invocation.value; XCTFail("Unmounted open cannot succeed") }
            catch is CancellationError { XCTAssertTrue(callerCancels) }
            catch WorkspaceApplicationOpenError.timedOut { XCTAssertFalse(callerCancels) }
            XCTAssertNil(h.registry.storeIfPresent(for: id))
            XCTAssertNil(h.registry.documentSessionIfPresent(for: id))
            XCTAssertTrue(session.isClosedForWindowClose)
            XCTAssertEqual(h.store.binaryOpenState?.phase, .cancelled)
        }
    }

    func testNeverMountedInstalledDocumentSurvivesAcknowledgementTimeout() async throws {
        let h = makeHarness(windowIdentity: { _ in nil })
        var owner: WorkspaceWindowID?
        h.router.installWindowPresenter { owner = $0 }
        do {
            _ = try await h.router.openBinaryAcknowledged(Self.url, timeout: .seconds(1))
            XCTFail("No native window can acknowledge success")
        } catch WorkspaceApplicationOpenError.timedOut {}
        let id = try XCTUnwrap(owner)
        XCTAssertTrue(h.registry.storeIfPresent(for: id) === h.store)
        XCTAssertFalse(try XCTUnwrap(h.registry.documentSessionIfPresent(for: id)).isClosedForWindowClose)
        XCTAssertFalse(h.store.snapshot.binaries.isEmpty, "Installed user data is not cleanup authority")
    }

    private static let url = URL(fileURLWithPath: "/acknowledged-intent-fixture")
    private func waitForChoice(_ store: WorkspaceStore) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while store.binaryOpenState?.phase != .choosing {
            guard clock.now < deadline else { throw WorkspaceApplicationOpenError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeHarness(gated: Bool = false, choosing: Bool = false, fails: Bool = false,
        realInspection: Bool = false,
        windowIdentity: (@MainActor (WorkspaceWindowID) -> ObjectIdentifier?)? = nil)
        -> (router: WorkspaceApplicationOpenRouter, registry: WorkspaceSessionRegistry,
            store: WorkspaceStore, loader: IntentAcknowledgementLoader) {
        let loader = IntentAcknowledgementLoader(gated: gated, fails: fails)
        let inspector = realInspection ? LoaderOptionsInspector() : LoaderOptionsInspector(operation: { _, _ in
            LoaderOptionsModel(fileName: "intent", formatDescription: "fixture", slices: choosing ? [
                .init(index: 0, architectureName: "arm64", offset: 0, size: 4),
                .init(index: 1, architectureName: "x86_64", offset: 4, size: 4),
            ] : [])
        })
        let store = WorkspaceStore(workspaceName: "intent", snapshot: .init(binaries: [], functions: [],
            instructions: [], xrefs: [], hexBytes: Data()), engine: AnalysisEngine(loader: loader),
            autosaveScheduler: nil, loaderOptionsInspector: inspector)
        let registry = WorkspaceSessionRegistry()
        let coordinator = WorkspaceOpenCoordinator(registry: registry, io: WorkspaceDocumentIO(),
                                                    windowActivator: IntentAcknowledgementActivator())
        return (WorkspaceApplicationOpenRouter(registry: registry, coordinator: coordinator,
            storeFactory: { store }, windowIdentity: windowIdentity ?? { _ in ObjectIdentifier(loader) }),
            registry, store, loader)
    }
}

@MainActor
private final class IntentAcknowledgementActivator: WorkspaceWindowActivating {
    func activateWindow(_ windowID: WorkspaceWindowID) -> Bool { true }
}

private final class IntentAcknowledgementLoader: BinaryLoader, @unchecked Sendable {
    private let gated: Bool
    private let fails: Bool
    private let entered = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    init(gated: Bool, fails: Bool) { self.gated = gated; self.fails = fails }
    func waitUntilEntered() { entered.wait() }
    func release() { gate.signal() }
    func load(at url: URL) throws -> LoadedBinary {
        entered.signal()
        if gated { gate.wait() }
        if fails { throw NSError(domain: "fixture failure", code: 1) }
        let bytes = Data([0xc0, 0x03, 0x5f, 0xd6])
        let text = BinarySection(name: ".text", address: 0x1000, size: 4, fileOffset: 0,
                                 isExecutable: true, fileSize: 4)
        return LoadedBinary(name: "intent-fixture", path: url.path, isBundle: false,
            cpuType: MachOConstants.cpuTypeARM64, fileTypeName: "fixture", architectureDisplayName: "arm64",
            metadata: .empty, bytes: bytes, sliceOffset: 0, sliceSize: 4, sections: [text],
            executableTextSection: text, entryPointAddress: 0x1000, symbols: [], imports: [],
            indirectSymbols: [], exports: [], stringLiterals: [], functionStarts: [0x1000], objcSelectors: [:])
    }
}
