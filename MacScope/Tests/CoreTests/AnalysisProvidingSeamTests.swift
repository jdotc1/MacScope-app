import Foundation
import XCTest
@testable import MacScope

/// WS-3 Stage 2: the store talks to `AnalysisProviding`, not to `AnalysisEngine`. These tests
/// prove SUBSTITUTABILITY — a store driven by a provider that is not the engine imports,
/// cancels, and reports errors identically. This is the contract the WS-3 Stage 3 XPC worker
/// slots into; if these hold, crash isolation is a provider swap, not a store rewrite.
@MainActor
final class AnalysisProvidingSeamTests: XCTestCase {

    func testImportRunsThroughAnInjectedNonEngineProvider() async {
        let provider = ScriptedProvider(result: .success(Self.cannedSnapshot()))
        let store = Self.makeEmptyStore(provider: provider)

        store.beginImport(url: URL(fileURLWithPath: "/tmp/seam-fixture"))
        await store.awaitPendingImport()

        XCTAssertEqual(store.snapshot.binaries.first?.name, "seam-fixture")
        XCTAssertEqual(store.snapshot.functions.count, 1)
        XCTAssertNil(store.lastIssue)
        XCTAssertEqual(provider.openBinaryCalls, 1, "the import went through the seam, not the engine")
    }

    func testProviderFailureSurfacesAsImportIssue() async {
        struct WorkerExploded: Error, LocalizedError {
            var errorDescription: String? { "analysis worker exploded" }
        }
        let provider = ScriptedProvider(result: .failure(WorkerExploded()))
        let store = Self.makeEmptyStore(provider: provider)

        store.beginImport(url: URL(fileURLWithPath: "/tmp/seam-fixture"))
        await store.awaitPendingImport()

        XCTAssertEqual(store.lastIssue, "analysis worker exploded")
        XCTAssertTrue(store.snapshot.binaries.isEmpty, "a failed provider leaves the workspace untouched")
    }

    func testProviderCancellationStaysBenignThroughTheSeam() async {
        let provider = ScriptedProvider(result: .failure(AnalysisCancelled()))
        let store = Self.makeEmptyStore(provider: provider)

        store.beginImport(url: URL(fileURLWithPath: "/tmp/seam-fixture"))
        await store.awaitPendingImport()

        XCTAssertNil(store.lastIssue, "AnalysisCancelled from ANY provider is benign, not an error")
        XCTAssertTrue(store.snapshot.binaries.isEmpty)
    }

    // MARK: - Fixtures

    private static func makeEmptyStore(provider: ScriptedProvider) -> WorkspaceStore {
        WorkspaceStore(
            workspaceName: "seam",
            snapshot: WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            engine: provider,
            autosaveScheduler: nil
        )
    }

    private static func cannedSnapshot() -> WorkspaceSnapshot {
        let image = BinaryImage(
            id: UUID(), name: "seam-fixture", path: "/tmp/seam-fixture",
            kind: "fixture", architecture: "arm64"
        )
        let function = FunctionSummary(
            id: UUID(), name: "seam_fn", startAddress: 0x1000, endAddress: 0x1004, confidence: 1.0
        )
        let row = InstructionRow(
            address: 0x1000, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "",
            hasBreakpoint: false, comment: nil
        )
        return WorkspaceSnapshot(
            binaries: [image], functions: [function], instructions: [row], xrefs: [],
            hexBytes: Data([0xc0, 0x03, 0x5f, 0xd6])
        )
    }
}

/// A provider that is deliberately NOT `AnalysisEngine`: returns a scripted result and counts
/// calls. Lock-protected because the protocol is `Sendable` and calls hop executors.
private final class ScriptedProvider: AnalysisProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<WorkspaceSnapshot, Error>
    private var _openBinaryCalls = 0

    var openBinaryCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _openBinaryCalls
    }

    init(result: Result<WorkspaceSnapshot, Error>) {
        self.result = result
    }

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        try result.get()
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        recordOpenBinaryCall()
        return try result.get()
    }

    /// Synchronous so the locking never sits directly in an async frame (Swift 6 forbids
    /// `NSLock.lock()` there); calling a sync method that locks internally is fine.
    private func recordOpenBinaryCall() {
        lock.lock()
        _openBinaryCalls += 1
        lock.unlock()
    }
}
