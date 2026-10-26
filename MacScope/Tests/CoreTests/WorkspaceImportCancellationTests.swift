import Foundation
import XCTest
@testable import MacScope

/// WS-3 import-cancel UX: the INITIAL import is cancellable (Cancel button / Esc on the
/// "Indexing binary" panel, and window-close via `deinit`). Cancelling must unwind cleanly —
/// `isImporting` clears, NO error banner is shown (a user cancel is not a failure), and the
/// workspace keeps its prior (empty) state. The engine-level cooperative cancellation is proven
/// separately in `AnalysisCancellationTests`; here we pin the store's wiring end-to-end.
@MainActor
final class WorkspaceImportCancellationTests: XCTestCase {

    // MARK: - Cancel semantics

    func testCancelDuringImportUnwindsCleanlyWithNoError() async {
        let loader = GatedLoader(binary: Self.fixtureBinary())
        let store = Self.makeEmptyStore(loader: loader)

        store.beginImport(url: URL(fileURLWithPath: "/tmp/ignored"))
        // Wait — off the main actor — until load() is actually running, so the import is genuinely
        // in flight (isImporting set, engine suspended inside the loader) before we cancel.
        await Task.detached { loader.waitUntilEntered() }.value
        XCTAssertTrue(store.isImporting, "import is in flight while the loader is gated")

        store.cancelImport()
        loader.release()             // let load() return; the post-load checkpoint sees the cancel
        await store.awaitPendingImport()

        XCTAssertFalse(store.isImporting, "the indicator clears when the cancelled import unwinds")
        XCTAssertNil(store.lastIssue, "a user-initiated cancel must not surface as an error")
        XCTAssertTrue(store.snapshot.binaries.isEmpty, "the workspace keeps its prior empty state")
    }

    func testCancelImportIsANoOpWhenNothingIsImporting() {
        let store = Self.makeEmptyStore(loader: GatedLoader(binary: Self.fixtureBinary()))
        XCTAssertFalse(store.isImporting)
        store.cancelImport()          // must not crash, set an error, or flip any state
        XCTAssertFalse(store.isImporting)
        XCTAssertNil(store.lastIssue)
    }

    // MARK: - The gate harness completes a normal import (control)

    func testUncancelledImportCompletesThroughTheGate() async {
        let loader = GatedLoader(binary: Self.fixtureBinary())
        let store = Self.makeEmptyStore(loader: loader)

        store.beginImport(url: URL(fileURLWithPath: "/tmp/ignored"))
        await Task.detached { loader.waitUntilEntered() }.value
        loader.release()              // release WITHOUT cancelling — the import should complete
        await store.awaitPendingImport()

        XCTAssertFalse(store.isImporting)
        XCTAssertNil(store.lastIssue)
        XCTAssertEqual(store.snapshot.binaries.count, 1, "the import landed a binary")
        XCTAssertEqual(store.snapshot.instructions.first?.mnemonic, "import_stub")
    }

    // MARK: - Fixtures

    private static func makeEmptyStore(loader: GatedLoader) -> WorkspaceStore {
        WorkspaceStore(
            workspaceName: "import-cancel",
            snapshot: WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            engine: AnalysisEngine(loader: loader, decoder: ImportStubDisassembler()),
            autosaveScheduler: nil
        )
    }

    private static func fixtureBinary() -> LoadedBinary {
        let payload = Data([0xc0, 0x03, 0x5f, 0xd6])
        let text = BinarySection(
            name: ".text", address: 0x1000, size: UInt64(payload.count), fileOffset: 0,
            isExecutable: true, fileSize: UInt64(payload.count)
        )
        return LoadedBinary(
            name: "import-fixture", path: "/tmp/import-fixture", isBundle: false,
            cpuType: MachOConstants.cpuTypeARM64,
            fileTypeName: "fixture", architectureDisplayName: "arm64",
            metadata: .empty,
            bytes: payload, sliceOffset: 0, sliceSize: UInt64(payload.count),
            sections: [text], executableTextSection: text, entryPointAddress: 0x1000,
            symbols: [], imports: [], indirectSymbols: [], exports: [], stringLiterals: [],
            functionStarts: [0x1000], objcSelectors: [:]
        )
    }
}

/// A loader that blocks inside `load()` until the test releases it, so an import can be observed
/// (and cancelled) mid-flight deterministically. `entered` reports that `load()` is running;
/// `gate` holds it there until `release()`.
private final class GatedLoader: BinaryLoader, @unchecked Sendable {
    private let binary: LoadedBinary
    private let entered = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)

    init(binary: LoadedBinary) {
        self.binary = binary
    }

    func load(at url: URL) throws -> LoadedBinary {
        entered.signal()
        gate.wait()
        return binary
    }

    func waitUntilEntered() { entered.wait() }
    func release() { gate.signal() }
}

private struct ImportStubDisassembler: Disassembler {
    func decode(_ bytes: Data, baseAddress: UInt64, maxInstructionCount: Int) -> [DecodedInstruction] {
        guard !bytes.isEmpty else { return [] }
        return [
            DecodedInstruction(
                address: baseAddress, bytes: Array(bytes.prefix(4)),
                mnemonic: "import_stub", operands: "", branchTarget: nil, comment: nil, flow: .return
            )
        ]
    }
}
