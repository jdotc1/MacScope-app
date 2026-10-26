import Foundation
import XCTest
@testable import MacScope

/// WS-3 / f9: cooperative cancellation in the analysis pipeline. A cancelled token must unwind
/// `analyze` at the NEXT pass boundary (`AnalysisCancelled`), and `openBinary` must fold Swift
/// task cancellation into the token so the store's existing `reanalysisTask?.cancel()` actually
/// halts in-flight work. The default `.never` token must leave every existing call site — and
/// the golden-oracle differential, which calls `analyze` directly — byte-identical.
final class AnalysisCancellationTests: XCTestCase {

    // MARK: - Default token (source + behavior compatibility)

    func testAnalyzeSucceedsWithDefaultNeverToken() throws {
        // No `cancellation:` argument at all — proves the trailing default keeps the
        // pre-cancellation call shape working and produces a normal snapshot.
        let snapshot = try AnalysisEngine(
            loader: CancellationStubLoader(binary: Self.fixtureBinary()),
            decoder: CancellationStubDisassembler()
        ).analyze(url: URL(fileURLWithPath: "/tmp/ignored"))

        XCTAssertEqual(snapshot.instructions.first?.mnemonic, "cancel_stub")
        XCTAssertEqual(snapshot.functions.count, 1)
    }

    // MARK: - Entry checkpoint

    func testAnalyzeThrowsBeforeLoadingWhenAlreadyCancelled() {
        // The loader throws a DISTINCT error if it is ever invoked; getting `AnalysisCancelled`
        // (not that error) proves the entry checkpoint fired before any work started.
        let loader = ThrowingProbeLoader()

        XCTAssertThrowsError(
            try AnalysisEngine(loader: loader, decoder: CancellationStubDisassembler())
                .analyze(
                    url: URL(fileURLWithPath: "/tmp/ignored"),
                    cancellation: AnalysisCancellationToken { true }
                )
        ) { error in
            XCTAssertTrue(error is AnalysisCancelled, "expected AnalysisCancelled, got \(error)")
        }
    }

    // MARK: - Interior checkpoints

    func testAnalyzeObservesCancellationAtAnInteriorPassBoundary() {
        // Tie cancellation to the semantic boundary being proved instead of to a count of token
        // polls. Cancellation-aware loaders may legitimately poll more than once before entering
        // their legacy `load(at:)` implementation; those pre-load polls must not make this test
        // cancel early. Once the loader records entry, the next pipeline boundary must unwind.
        let loader = RecordingStubLoader(binary: Self.fixtureBinary())
        let token = AnalysisCancellationToken { loader.didLoad }

        XCTAssertThrowsError(
            try AnalysisEngine(loader: loader, decoder: CancellationStubDisassembler())
                .analyze(url: URL(fileURLWithPath: "/tmp/ignored"), cancellation: token)
        ) { error in
            XCTAssertTrue(error is AnalysisCancelled, "expected AnalysisCancelled, got \(error)")
        }
        XCTAssertTrue(loader.didLoad, "the entry checkpoint passed, so the loader must have run")
    }

    // MARK: - Task-cancellation folding (the store's reanalysisTask.cancel() path)

    func testOpenBinaryFoldsTaskCancellationIntoTheToken() async {
        // Cancel the surrounding task BEFORE calling openBinary (self-cancel is deterministic —
        // no race against task startup). openBinary's combined token must observe it even
        // though the caller passed no explicit token, exactly the store's cancel path.
        let engine = AnalysisEngine(
            loader: CancellationStubLoader(binary: Self.fixtureBinary()),
            decoder: CancellationStubDisassembler()
        )

        let result = await Task { () -> Result<WorkspaceSnapshot, Error> in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                return .success(try await engine.openBinary(url: URL(fileURLWithPath: "/tmp/ignored")))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success:
            XCTFail("openBinary inside a cancelled task must unwind, not produce a snapshot")
        case .failure(let error):
            XCTAssertTrue(error is AnalysisCancelled, "expected AnalysisCancelled, got \(error)")
        }
    }

    func testOpenBinarySucceedsInAnUncancelledTask() async throws {
        let engine = AnalysisEngine(
            loader: CancellationStubLoader(binary: Self.fixtureBinary()),
            decoder: CancellationStubDisassembler()
        )
        let snapshot = try await engine.openBinary(url: URL(fileURLWithPath: "/tmp/ignored"))
        XCTAssertEqual(snapshot.instructions.first?.mnemonic, "cancel_stub")
    }

    // MARK: - Fixture

    private static func fixtureBinary() -> LoadedBinary {
        let payload = Data([0xc0, 0x03, 0x5f, 0xd6, 0xc0, 0x03, 0x5f, 0xd6])
        let text = BinarySection(
            name: ".text", address: 0x1000, size: UInt64(payload.count), fileOffset: 0,
            isExecutable: true, fileSize: UInt64(payload.count)
        )
        return LoadedBinary(
            name: "cancel-fixture", path: "/tmp/cancel-fixture", isBundle: false,
            cpuType: MachOConstants.cpuTypeARM64,
            fileTypeName: "fixture", architectureDisplayName: "arm64",
            metadata: .empty,
            bytes: payload,
            sliceOffset: 0,
            sliceSize: UInt64(payload.count),
            sections: [text], executableTextSection: text, entryPointAddress: 0x1000,
            symbols: [], imports: [], indirectSymbols: [], exports: [], stringLiterals: [],
            functionStarts: [0x1000], objcSelectors: [:]
        )
    }
}

// MARK: - Stubs

private struct CancellationStubLoader: BinaryLoader {
    let binary: LoadedBinary
    func load(at url: URL) throws -> LoadedBinary { binary }
}

/// Throws a sentinel error when invoked — used to prove the entry checkpoint rejects a cancelled
/// token BEFORE any loading happens.
private struct ThrowingProbeLoader: BinaryLoader {
    struct LoaderWasInvoked: Error {}
    func load(at url: URL) throws -> LoadedBinary { throw LoaderWasInvoked() }
}

/// Records that loading happened — used to prove an interior (post-load) checkpoint fired. The
/// token closure is `@Sendable`, so keep the observation lock-protected even though `analyze` is
/// currently synchronous; the test remains sound if loader/token execution later changes threads.
private final class RecordingStubLoader: BinaryLoader, @unchecked Sendable {
    let binary: LoadedBinary
    private let lock = NSLock()
    private var loaded = false

    var didLoad: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loaded
    }

    init(binary: LoadedBinary) {
        self.binary = binary
    }

    func load(at url: URL) throws -> LoadedBinary {
        lock.lock()
        loaded = true
        lock.unlock()
        return binary
    }
}

private struct CancellationStubDisassembler: Disassembler {
    func decode(_ bytes: Data, baseAddress: UInt64, maxInstructionCount: Int) -> [DecodedInstruction] {
        guard !bytes.isEmpty else { return [] }
        return [
            DecodedInstruction(
                address: baseAddress,
                bytes: Array(bytes.prefix(4)),
                mnemonic: "cancel_stub",
                operands: "",
                branchTarget: nil,
                comment: nil,
                flow: .return
            )
        ]
    }
}
