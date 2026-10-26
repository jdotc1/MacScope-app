import CryptoKit
import Foundation
import XCTest
@testable import MacScope

/// D10 native whole-image export on fixtures: truthful per-function status, no MacScope fallback,
/// cancellation reaching the native request, disk failure, stale owner, and limit handling.
@MainActor
final class NativePseudocodeBatchExportTests: XCTestCase {
    private typealias Batch = NativePseudocodeBatchExport
    private typealias Operation = NativePseudocodeBatchExportOperation

    private nonisolated static let artifactUUID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    private nonisolated static let fingerprint = String(repeating: "b", count: 64)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeBatchExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func owner(documentGeneration: UInt64 = 7) -> Operation.Owner {
        .init(documentID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
              windowGeneration: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
              documentGeneration: documentGeneration, imageSlot: 0,
              binaryID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    }

    private nonisolated static func item(_ n: UInt8, _ address: UInt64) -> Batch.Item {
        .init(functionID: UUID(uuidString: "F0000000-0000-0000-0000-0000000000\(String(format: "%02X", n))")!,
              startAddress: address, name: "fn_\(n)")
    }

    private func operation(_ items: [Batch.Item], limits: Batch.Limits = .init()) -> Operation {
        let context = Batch.Context(
            workspaceID: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!, imageName: "fixture",
            imageSlot: .primary, binaryID: owner().binaryID, artifactUUID: Self.artifactUUID,
            analysisInputFingerprintSHA256: Self.fingerprint, documentGeneration: 7,
            snapshot: WorkspaceStore.bootstrapForPreviewFixture().snapshot)
        return Operation(owner: owner(), context: context, items: items, limits: limits)
    }

    private func spoolFactory() -> @Sendable () throws -> any NativePseudocodeBatchSink {
        let parent = directory.appendingPathComponent("spool", isDirectory: true)
        return {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            return try NativePseudocodeBatchSpool(parent: parent)
        }
    }

    private var spoolEntries: [String] {
        (try? FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent("spool").path)) ?? []
    }

    // MARK: - Fixture native results

    private nonisolated static func execution(for request: NativeDecompilerProjectionRequest, address: UInt64,
                           text: String = "void f(void) {}\n", complete: Bool = true, truncated: Bool = false,
                           functionID: String? = nil, available: Bool = true,
                           document: Bool = true) -> NativeDecompilerValidatedExecution {
        let requestSHA = String(repeating: "a", count: 64)
        let success = NativeDecompilerWireSuccess(
            availability: .init(
                available: available, reasonCode: "available",
                runtimeIdentity: .init(backendID: "native-decompiler", engineVersion: "12.1.2",
                    engineRevision: "engine-revision", wrapperVersion: "1", wrapperRevision: "wrapper-revision",
                    packageManifestSHA256: String(repeating: "d", count: 64),
                    packageTreeSHA256: String(repeating: "e", count: 64),
                    languageID: "AARCH64:LE:64:AppleSilicon", compilerSpecID: "default",
                    targetProfileID: "apple-aarch64-pac-visible-clobber-v1",
                    contextProfileSHA256: String(repeating: "c", count: 64)),
                capabilities: .init(nativeDecompilerHeritage: true, completeRegisterSSA: false, memorySSA: false,
                    recoveredVariables: false, recoveredTypes: false, structuredControlFlow: true,
                    tokenizedPseudocode: false, imageQualifiedSourceRanges: true)),
            result: .init(
                requestID: UUID(), requestSHA256: requestSHA,
                image: .init(imageID: "image:fixture", uuid: Self.artifactUUID, preferredLoadAddress: .init(0x1000)),
                function: .init(functionID: functionID ?? request.functionID.uuidString.lowercased(), name: "f",
                                entryAddress: .init(address), endAddressExclusive: .init(address + 4)),
                addressSpaces: [], types: [], instructions: [], varnodes: [], operations: [], blocks: [],
                edges: [], ssaValues: [], ssaBindings: [], phis: [], memoryVersions: [], memoryPhis: [],
                memoryEffects: [], variables: [], calls: [], regions: [], tokens: [],
                pseudocodeDocument: document ? .init(text: text, language: "c", isComplete: complete,
                                                     isTruncated: truncated) : nil,
                warnings: []))
        return NativeDecompilerValidatedExecution(
            requestSHA256: requestSHA, analysisInputFingerprintSHA256: request.analysisInputFingerprintSHA256,
            imageSlot: request.imageSlot, functionID: request.functionID, success: success,
            source: .validatedCache)
    }

    /// One capture per export; each function becomes a projection request on the captured snapshot.
    private struct ScriptedDecompiler: NativePseudocodeBatchDecompiling {
        let ledger = SessionLedger()
        var beginError: (any Error & Sendable)?
        let respond: @Sendable (NativeDecompilerProjectionRequest) async throws -> NativeDecompilerValidatedExecution

        init(beginError: (any Error & Sendable)? = nil,
             respond: @escaping @Sendable (NativeDecompilerProjectionRequest) async throws -> NativeDecompilerValidatedExecution) {
            self.beginError = beginError
            self.respond = respond
        }

        func beginBatchExport(snapshot: WorkspaceSnapshot, imageSlot: ImageSlot) async throws
            -> any NativePseudocodeBatchSession {
            ledger.record(.begin)
            if let beginError { throw beginError }
            return ScriptedSession(snapshot: snapshot, imageSlot: imageSlot, ledger: ledger, respond: respond)
        }
    }

    private struct ScriptedSession: NativePseudocodeBatchSession {
        let snapshot: WorkspaceSnapshot
        let imageSlot: ImageSlot
        let ledger: SessionLedger
        let respond: @Sendable (NativeDecompilerProjectionRequest) async throws -> NativeDecompilerValidatedExecution

        func decompile(functionID: UUID) async throws -> NativeDecompilerValidatedExecution {
            ledger.record(.decompile)
            let request = try NativeDecompilerProjectionRequest(
                workspace: snapshot, imageSlot: imageSlot, functionID: functionID,
                analysisInputFingerprintSHA256: NativePseudocodeBatchExportTests.fingerprint)
            return try await respond(request)
        }

        func cancel() { ledger.record(.cancel) }
        func retire() async { ledger.record(.retire) }
    }

    // MARK: - Tests

    func testMixedBatchPublishesTruthfulReportWithoutMacScopeFallback() async throws {
        let items = [Self.item(1, 0x1000), Self.item(2, 0x1010), Self.item(3, 0x1020), Self.item(4, 0x1030),
                     Self.item(5, 0x1040), Self.item(6, 0x1050), Self.item(7, 0x1060)]
        let op = operation(items.reversed())
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.functionID, $0.startAddress) })
        let decompiler = ScriptedDecompiler { request in
            let address = byID[request.functionID]!
            switch address {
            case 0x1000: return Self.execution(for: request, address: address, text: "int one(void) { return 1; }\n")
            case 0x1010: throw NativeDecompilerOwnerAdmissionError.terminal(
                .terminal(.provider(.nativeFailure, detail: "native-provider-output-budget-exceeded")))
            case 0x1020: return Self.execution(for: request, address: address, text: "void cut(void) {\n", complete: false, truncated: true)
            case 0x1030: return Self.execution(for: request, address: address, text: "void part(void);\n", complete: false)
            case 0x1040: throw NativeDecompilerSnapshotProjectionError.binaryNotFound
            case 0x1050: return Self.execution(for: request, address: address, functionID: "forged")
            default: return Self.execution(for: request, address: address, document: false)
            }
        }
        let output = try await op.run(decompiler: decompiler, makeSink: spoolFactory())
        let destination = directory.appendingPathComponent("out.txt")
        let reportURL = try op.publish(output, currentOwner: owner(), to: destination)
        XCTAssertTrue(reportURL.lastPathComponent.hasPrefix("out.txt.") && reportURL.lastPathComponent.hasSuffix(".report.json"))
        XCTAssertEqual(spoolEntries, [], "spool removed after publication")
        for url in [destination, reportURL] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o644, url.lastPathComponent)
        }

        let text = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("// MacScope pseudocode export — provider: Native, whole image"))
        XCTAssertTrue(text.contains("// ===== fn_1 @ 0x1000 — native =====\n// function f0000000-0000-0000-0000-000000000001; request \(String(repeating: "a", count: 64))\nint one(void) { return 1; }\n"))
        XCTAssertTrue(text.contains("// ===== fn_2 @ 0x1010 — not exported: refused (native-provider-output-budget-exceeded) ====="))
        XCTAssertTrue(text.contains("— native, truncated =====") && text.contains("void cut(void) {\n"))
        XCTAssertTrue(text.contains("— native, incomplete =====") && text.contains("void part(void);\n"))
        XCTAssertTrue(text.contains("fn_6 @ 0x1050 — not exported: failed (validation-identity-mismatch)"))
        XCTAssertTrue(text.contains("fn_7 @ 0x1060 — not exported: refused (no-native-document)"))

        let report = try JSONDecoder().decode(Batch.Report.self, from: Data(contentsOf: reportURL))
        XCTAssertEqual(report.rows.map(\.startAddress), ["0x1000", "0x1010", "0x1020", "0x1030", "0x1040", "0x1050", "0x1060"])
        XCTAssertEqual(report.rows.map(\.status), [.exported, .refused, .truncated, .incomplete, .refused, .failed, .refused])
        XCTAssertEqual(report.rows[4].reason, "projection-binaryNotFound")
        XCTAssertEqual(report.rows[2].reason, "native-document-truncated-output-budget")
        XCTAssertEqual(report.rows[3].reason, "native-document-incomplete")
        XCTAssertNil(report.rows[0].reason)
        XCTAssertTrue(report.rows.allSatisfy { $0.provider == "native" })
        XCTAssertEqual(report.rows.map { $0.provenance != nil }, [true, false, true, true, false, false, false])
        XCTAssertEqual(report.rows[0].provenance?.source, "validated-cache")
        XCTAssertEqual(report.rows[0].provenance?.runtime.backendID, "native-decompiler")
        XCTAssertEqual(report.counts, ["exported": 1, "truncated": 1, "incomplete": 1, "refused": 3, "failed": 1])
        let bytes = try Data(contentsOf: destination)
        XCTAssertEqual(report.textByteCount, bytes.count)
        XCTAssertEqual(report.textSHA256, SHA256Hex.of(bytes))
    }

    func testCancelDuringNativeRequestCancelsItAndNeverPublishes() async throws {
        let op = operation([Self.item(1, 0x1000), Self.item(2, 0x1010)])
        let entered = expectation(description: "native request started")
        let observed = CancelFlag()
        let decompiler = ScriptedDecompiler { _ in
            entered.fulfill()
            await withTaskCancellationHandler {
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            } onCancel: { observed.set() }
            throw CancellationError()
        }
        let factory = spoolFactory()
        let run = Task { try await op.run(decompiler: decompiler, makeSink: factory) }
        await fulfillment(of: [entered], timeout: 5)
        op.cancel()
        let result = await run.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertTrue(observed.value, "cancellation reached the native request")
        XCTAssertEqual(spoolEntries, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("out.txt").path))
    }

    func testSpoolDiskFailureFailsExportAndRemovesSpool() async throws {
        let op = operation([Self.item(1, 0x1000), Self.item(2, 0x1010)])
        let failing = FailingSink(failOnAppend: 2)
        let decompiler = ScriptedDecompiler { Self.execution(for: $0, address: $0.functionID == Self.item(1, 0).functionID ? 0x1000 : 0x1010) }
        do {
            _ = try await op.run(decompiler: decompiler, makeSink: { failing })
            XCTFail("disk failure must fail the export")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileWriteOutOfSpace)
        }
        XCTAssertTrue(failing.removed)
    }

    func testReportCommitFailureRestoresPriorTextAndRemovesSpool() async throws {
        let op = operation([Self.item(1, 0x1000)])
        let decompiler = ScriptedDecompiler { Self.execution(for: $0, address: 0x1000) }
        let output = try await op.run(decompiler: decompiler, makeSink: spoolFactory())
        let destination = directory.appendingPathComponent("out.txt")
        try Data("prior\n".utf8).write(to: destination)
        XCTAssertThrowsError(try op.publish(output, currentOwner: owner(), to: destination,
                                            fileManager: ReportBlockingFileManager()))
        XCTAssertEqual(try Data(contentsOf: destination), Data("prior\n".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".report.json") })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["out.txt", "spool"])
        XCTAssertEqual(spoolEntries, [])
    }

    func testStaleOwnerStopsBeforeNextFunctionAndRefusesPublication() async throws {
        let op = operation([Self.item(1, 0x1000), Self.item(2, 0x1010)])
        let calls = Counter()
        let decompiler = ScriptedDecompiler { calls.increment(); return Self.execution(for: $0, address: 0x1000) }
        let checks = Counter()
        do {
            _ = try await op.run(decompiler: decompiler, isCurrent: { checks.increment() == 1 }, makeSink: spoolFactory())
            XCTFail("stale owner must fail the export")
        } catch { XCTAssertEqual(error as? Operation.Failure, .staleOwner) }
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(spoolEntries, [])

        let second = operation([Self.item(1, 0x1000)])
        let output = try await second.run(decompiler: decompiler, makeSink: spoolFactory())
        let destination = directory.appendingPathComponent("out.txt")
        XCTAssertThrowsError(try second.publish(output, currentOwner: owner(documentGeneration: 8), to: destination)) {
            XCTAssertEqual($0 as? Operation.Failure, .staleOwner)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRuntimeShutdownIsFatalNotAPerFunctionRefusal() async throws {
        let op = operation([Self.item(1, 0x1000), Self.item(2, 0x1010)])
        let decompiler = ScriptedDecompiler { _ in throw NativeDecompilerProcessRuntimeError.shutDown }
        do {
            _ = try await op.run(decompiler: decompiler, makeSink: spoolFactory())
            XCTFail("shutdown must end the export")
        } catch { XCTAssertEqual(error as? Operation.Failure, .sessionEnded("native-runtime-shut-down")) }
        XCTAssertEqual(spoolEntries, [])
    }

    func testOversizedFunctionIsReportedAndAggregateLimitFailsInsteadOfTruncating() async throws {
        var limits = Batch.Limits()
        limits.maximumFunctionTextBytes = 8
        let small = operation([Self.item(1, 0x1000), Self.item(2, 0x1010)], limits: limits)
        let decompiler = ScriptedDecompiler { request in
            request.functionID == Self.item(1, 0).functionID
                ? Self.execution(for: request, address: 0x1000, text: "tiny\n")
                : Self.execution(for: request, address: 0x1010, text: String(repeating: "x", count: 9))
        }
        let output = try await small.run(decompiler: decompiler, makeSink: spoolFactory())
        XCTAssertEqual(output.report.rows.map(\.status), [.exported, .failed])
        XCTAssertEqual(output.report.rows[1].reason, "function-text-over-limit")
        small.cancel()
        XCTAssertEqual(spoolEntries, [], "cancelling a ready output removes its spool")

        var tight = Batch.Limits()
        tight.maximumTotalTextBytes = 1_000
        let big = operation([Self.item(1, 0x1000), Self.item(2, 0x1010)], limits: tight)
        let wide = ScriptedDecompiler {
            Self.execution(for: $0, address: $0.functionID == Self.item(1, 0).functionID ? 0x1000 : 0x1010,
                      text: String(repeating: "y", count: 200))
        }
        do {
            _ = try await big.run(decompiler: wide, makeSink: spoolFactory())
            XCTFail("aggregate limit must fail the export")
        } catch { XCTAssertEqual(error as? Operation.Failure, .aggregateTextLimit) }
        XCTAssertEqual(spoolEntries, [])
    }

    // MARK: - Batch capture (D09 lease)

    func testOneCapturePerExportAndRetiredAfterSuccess() async throws {
        let items = [Self.item(1, 0x1000), Self.item(2, 0x1010), Self.item(3, 0x1020)]
        let addresses = Dictionary(uniqueKeysWithValues: items.map { ($0.functionID, $0.startAddress) })
        let decompiler = ScriptedDecompiler { Self.execution(for: $0, address: addresses[$0.functionID]!) }
        let output = try await operation(items).run(decompiler: decompiler, makeSink: spoolFactory())
        XCTAssertEqual(output.report.rows.map(\.status), [.exported, .exported, .exported])
        XCTAssertEqual(decompiler.ledger.events, [.begin, .decompile, .decompile, .decompile, .retire])
    }

    func testFatalFailureCancelsAndRetiresCapture() async throws {
        let decompiler = ScriptedDecompiler { _ in throw NativeDecompilerProcessRuntimeError.shutDown }
        do {
            _ = try await operation([Self.item(1, 0x1000), Self.item(2, 0x1010)])
                .run(decompiler: decompiler, makeSink: spoolFactory())
            XCTFail("shutdown must end the export")
        } catch { XCTAssertEqual(error as? Operation.Failure, .sessionEnded("native-runtime-shut-down")) }
        XCTAssertEqual(decompiler.ledger.events, [.begin, .decompile, .cancel, .retire])
        XCTAssertEqual(spoolEntries, [])
    }

    func testCancelReachesCaptureSynchronouslyAndRetires() async throws {
        let op = operation([Self.item(1, 0x1000), Self.item(2, 0x1010)])
        let entered = expectation(description: "native request started")
        let decompiler = ScriptedDecompiler { _ in
            entered.fulfill()
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            throw CancellationError()
        }
        let factory = spoolFactory()
        let run = Task { try await op.run(decompiler: decompiler, makeSink: factory) }
        await fulfillment(of: [entered], timeout: 5)
        op.cancel()
        XCTAssertTrue(decompiler.ledger.events.contains(.cancel), "cancel() closes the capture before returning")
        let result = await run.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(decompiler.ledger.events.filter { $0 == .retire }.count, 1)
        XCTAssertEqual(decompiler.ledger.events.filter { $0 == .decompile }.count, 1)
        XCTAssertEqual(spoolEntries, [])
    }

    func testCaptureRefusalIsReportedForEveryFunction() async throws {
        let decompiler = ScriptedDecompiler(beginError: NativeDecompilerSnapshotProjectionError.binaryNotFound) { _ in
            XCTFail("no function is requested without a capture")
            throw CancellationError()
        }
        let output = try await operation([Self.item(1, 0x1000), Self.item(2, 0x1010)])
            .run(decompiler: decompiler, makeSink: spoolFactory())
        XCTAssertEqual(output.report.rows.map(\.status), [.refused, .refused])
        XCTAssertEqual(output.report.rows.map(\.reason), ["projection-binaryNotFound", "projection-binaryNotFound"])
        XCTAssertEqual(decompiler.ledger.events, [.begin])

        let shutDown = ScriptedDecompiler(beginError: NativeDecompilerProcessRuntimeError.shutDown) { _ in
            throw CancellationError()
        }
        do {
            _ = try await operation([Self.item(1, 0x1000)]).run(decompiler: shutDown, makeSink: spoolFactory())
            XCTFail("a shut-down runtime ends the export")
        } catch { XCTAssertEqual(error as? Operation.Failure, .sessionEnded("native-runtime-shut-down")) }
        XCTAssertEqual(spoolEntries, [])
    }

    /// DP16 #693: exporting `sample.c` beside an earlier `sample.txt` export (same stem, other
    /// extension) keeps the earlier report; a user file with the old report name is untouched.
    func testReportsNeverCollideOrReplaceAnything() async throws {
        let userFile = directory.appendingPathComponent("sample.report.json")
        try Data("my own notes\n".utf8).write(to: userFile)
        var reports: [URL] = []
        for name in ["sample.txt", "sample.c"] {
            let op = operation([Self.item(1, 0x1000)])
            let output = try await op.run(decompiler: ScriptedDecompiler { Self.execution(for: $0, address: 0x1000) },
                                          makeSink: spoolFactory())
            reports.append(try op.publish(output, currentOwner: owner(), to: directory.appendingPathComponent(name)))
        }
        XCTAssertNotEqual(reports[0], reports[1])
        XCTAssertTrue(reports[0].lastPathComponent.hasPrefix("sample.txt."))
        XCTAssertTrue(reports[1].lastPathComponent.hasPrefix("sample.c."))
        for report in reports {
            XCTAssertEqual(try JSONDecoder().decode(Batch.Report.self, from: Data(contentsOf: report)).schema, Batch.reportSchema)
        }
        XCTAssertEqual(try Data(contentsOf: userFile), Data("my own notes\n".utf8), "the user's file is untouched")
    }

    /// Exporting the same text twice keeps both reports; the text header names its own report.
    func testRepeatedExportKeepsEachRunsReport() async throws {
        let destination = directory.appendingPathComponent("out.txt")
        var reports: [URL] = []
        for _ in 0..<2 {
            let op = operation([Self.item(1, 0x1000)])
            let output = try await op.run(decompiler: ScriptedDecompiler { Self.execution(for: $0, address: 0x1000) },
                                          makeSink: spoolFactory())
            reports.append(try op.publish(output, currentOwner: owner(), to: destination))
        }
        XCTAssertNotEqual(reports[0], reports[1])
        XCTAssertTrue(reports.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let text = try String(contentsOf: destination, encoding: .utf8)
        let tag = reports[1].lastPathComponent.dropFirst("out.txt.".count).prefix(8)
        XCTAssertTrue(text.contains(".\(tag).report.json"), "the text names the report of the run that wrote it")
    }

    /// The batch report names the provider's real failure cause, bounded to one line.
    func testTerminalProviderFailureCarriesBoundedDetail() {
        XCTAssertEqual(NativeDecompilerCoordinator.boundedFailureDetail("native-provider-output-budget-exceeded"),
                       "native-provider-output-budget-exceeded")
        XCTAssertEqual(NativeDecompilerCoordinator.boundedFailureDetail("two\nlines and spaces"), "two_lines_and_spaces")
        XCTAssertEqual(NativeDecompilerCoordinator.boundedFailureDetail(String(repeating: "x", count: 500))?.count, 160)
        XCTAssertNil(NativeDecompilerCoordinator.boundedFailureDetail(nil))
        XCTAssertEqual(NativeDecompilerPresentationTerminalReason.provider(.nativeFailure, detail: "d").diagnosticCode, "d")
        XCTAssertEqual(NativeDecompilerPresentationTerminalReason.provider(.timedOut).diagnosticCode, "provider-timed-out")
        XCTAssertEqual(NativeDecompilerPresentationTerminalReason.transportFailure.diagnosticCode, "transport-failure")
        XCTAssertEqual(NativeDecompilerOwnerAdmissionError.terminal(.terminal(.provider(.busy))),
                       .terminalProviderResult(reason: "provider-busy"))
    }
}

private enum SHA256Hex {
    static func of(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private final class SessionLedger: @unchecked Sendable {
    enum Event: Equatable { case begin, decompile, cancel, retire }
    private let lock = NSLock()
    private var storage: [Event] = []
    func record(_ event: Event) { lock.withLock { storage.append(event) } }
    var events: [Event] { lock.withLock { storage } }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    func set() { lock.withLock { storage = true } }
    var value: Bool { lock.withLock { storage } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    @discardableResult func increment() -> Int { lock.withLock { storage += 1; return storage } }
    var value: Int { lock.withLock { storage } }
}

private final class FailingSink: NativePseudocodeBatchSink, @unchecked Sendable {
    let textURL = URL(fileURLWithPath: "/nonexistent/native-export-test")
    private let lock = NSLock()
    private let failOnAppend: Int
    private var appends = 0
    private var didRemove = false
    init(failOnAppend: Int) { self.failOnAppend = failOnAppend }
    func append(_ data: Data) throws {
        try lock.withLock {
            appends += 1
            if appends == failOnAppend { throw CocoaError(.fileWriteOutOfSpace) }
        }
    }
    func finish() throws -> String { String(repeating: "0", count: 64) }
    func remove() { lock.withLock { didRemove = true } }
    var removed: Bool { lock.withLock { didRemove } }
}

/// Commits the text normally but refuses to move anything onto a report path.
private final class ReportBlockingFileManager: FileManager, @unchecked Sendable {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if dstURL.lastPathComponent.hasSuffix(".report.json") { throw CocoaError(.fileWriteNoPermission) }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
