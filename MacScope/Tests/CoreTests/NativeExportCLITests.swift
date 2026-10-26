import CryptoKit
import Foundation
import XCTest
@testable import MacScope

/// `--export-native-pseudocode` wiring without a real native runtime: mode-slot parsing, path
/// refusals, native-disabled / no-image refusals, and an end-to-end headless export through the
/// same `AllPseudocodeExportNativeCapture.makeOperation` + `publish` path the GUI uses.
@MainActor
final class NativeExportCLITests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeExportCLITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Arguments

    func testRequestParsesOnlyFromTheModeSlotWithExactArity() {
        let flag = NativeExportCLI.flag
        XCTAssertEqual(NativeExportCLI.request(from: ["MacScope", flag, "/bin/ls", "/tmp/out.txt"]),
                       .init(binaryPath: "/bin/ls", outputPath: "/tmp/out.txt"))
        XCTAssertNil(NativeExportCLI.request(from: ["MacScope"]))
        XCTAssertNil(NativeExportCLI.request(from: ["MacScope", flag]))
        XCTAssertNil(NativeExportCLI.request(from: ["MacScope", flag, "/bin/ls"]))
        XCTAssertNil(NativeExportCLI.request(from: ["MacScope", flag, "/bin/ls", "/tmp/a", "/tmp/b"]))
        XCTAssertNil(NativeExportCLI.request(from: ["MacScope", "--run-script", flag, "/bin/ls"]))
        XCTAssertNil(NativeExportCLI.request(from: ["MacScope", "\(flag)=/bin/ls", "/tmp/out.txt", "x"]))
        XCTAssertNil(CLIRunner.request(from: ["MacScope", flag, "/bin/ls", "/tmp/out.txt"]))
        XCTAssertNil(MCPLauncher.requestedBinary(from: ["MacScope", flag, "/bin/ls", "/tmp/out.txt"]))
    }

    func testResolveRequiresAbsolutePathsAndAnExistingOutputFolder() throws {
        let output = directory.appendingPathComponent("out.txt").path
        XCTAssertThrowsError(try NativeExportCLI.resolve(.init(binaryPath: "bin/ls", outputPath: output))) {
            XCTAssertEqual($0 as? NativeExportCLI.Refusal, .pathNotAbsolute("bin/ls"))
        }
        XCTAssertThrowsError(try NativeExportCLI.resolve(.init(binaryPath: "/bin/ls", outputPath: "out.txt"))) {
            XCTAssertEqual($0 as? NativeExportCLI.Refusal, .pathNotAbsolute("out.txt"))
        }
        let missing = directory.appendingPathComponent("missing", isDirectory: true)
        XCTAssertThrowsError(try NativeExportCLI.resolve(
            .init(binaryPath: "/bin/ls", outputPath: missing.appendingPathComponent("out.txt").path))) {
            XCTAssertEqual($0 as? NativeExportCLI.Refusal, .outputParentMissing(missing.standardizedFileURL.path))
        }
        XCTAssertThrowsError(try NativeExportCLI.resolve(.init(binaryPath: "/bin/ls", outputPath: directory.path))) {
            XCTAssertEqual($0 as? NativeExportCLI.Refusal, .outputIsDirectory(directory.standardizedFileURL.path))
        }
        let resolved = try NativeExportCLI.resolve(.init(binaryPath: "/bin/ls", outputPath: output))
        XCTAssertEqual(resolved.output.path, URL(fileURLWithPath: output).standardizedFileURL.path)
        XCTAssertTrue(resolved.binary.path.hasSuffix("/ls"))
    }

    // MARK: - Refusals

    func testRefusesWhenNativeIsDisabledOrThereIsNoImage() async throws {
        let output = directory.appendingPathComponent("out.txt")
        let decompiler = RecordingDecompiler(respond: { _, _ in XCTFail("not reached"); throw CancellationError() })
        do {
            _ = try await NativeExportCLI.export(store: try Self.fixtureStore(), to: output,
                                                 decompiler: decompiler, nativeEnabled: false)
            XCTFail("native disabled must refuse")
        } catch {
            XCTAssertEqual(error as? AllPseudocodeExportNativeCapture.Refusal, .nativeDisabled)
            XCTAssertEqual(NativeExportCLI.describe(error), AllPseudocodeExportNativeCapture.Refusal.nativeDisabled.message)
        }
        let empty = WorkspaceStore(workspaceName: "empty",
            snapshot: WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            engine: AnalysisEngine())
        do {
            _ = try await NativeExportCLI.export(store: empty, to: output, decompiler: decompiler, nativeEnabled: true)
            XCTFail("no image must refuse")
        } catch {
            XCTAssertEqual(error as? AllPseudocodeExportNativeCapture.Refusal, .noImage)
        }
        XCTAssertEqual(decompiler.ledger.begins, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testChangedBinaryIdentityFailsBeforePublication() async throws {
        let store = try Self.fixtureStore()
        let output = directory.appendingPathComponent("out.txt")
        let decompiler = RecordingDecompiler(respond: try Self.respond(store: store))
        struct Changed: Error {}
        do {
            _ = try await NativeExportCLI.export(store: store, to: output, decompiler: decompiler,
                                                 nativeEnabled: true, validateIdentity: { throw Changed() })
            XCTFail("a changed binary must not publish")
        } catch {
            // The fence fails before the first function: the export ends as stale, nothing published.
            XCTAssertEqual(error as? NativePseudocodeBatchExportOperation.Failure, .staleOwner)
        }
        XCTAssertEqual(decompiler.ledger.decompiles, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".report.json") })
    }

    // MARK: - End to end through the shared builder

    func testHeadlessExportPublishesTheGUIOperationsTextReportAndSummary() async throws {
        let store = try Self.fixtureStore()
        let expected = try AllPseudocodeExportNativeCapture.makeOperation(
            store: store, nativeEnabled: true, ownerGeneration: UUID())
        XCTAssertFalse(expected.items.isEmpty, "fixture has functions")
        let decompiler = RecordingDecompiler(respond: try Self.respond(store: store))
        let output = directory.appendingPathComponent("fixture-native.txt")

        let summary = try await NativeExportCLI.export(store: store, to: output, decompiler: decompiler,
                                                       nativeEnabled: true)

        let reportURL = URL(fileURLWithPath: summary.report)
        XCTAssertEqual(summary.text, output.path)
        XCTAssertTrue(reportURL.lastPathComponent.hasPrefix("fixture-native.txt.") && reportURL.lastPathComponent.hasSuffix(".report.json"))
        XCTAssertEqual(reportURL.deletingLastPathComponent().path, output.deletingLastPathComponent().path)
        XCTAssertEqual(decompiler.ledger.begins, 1)
        XCTAssertEqual(decompiler.ledger.decompiles, expected.items.count)
        XCTAssertEqual(decompiler.ledger.retires, 1)

        let text = try Data(contentsOf: output)
        let report = try JSONDecoder().decode(NativePseudocodeBatchExport.Report.self, from: Data(contentsOf: reportURL))
        XCTAssertEqual(summary.textSHA256, SHA256.hash(data: text).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(summary.textSHA256, report.textSHA256)
        XCTAssertEqual(summary.counts, report.counts)
        XCTAssertEqual(report.counts["exported"], expected.items.count - 1)
        XCTAssertEqual(report.counts["refused"], 1)
        XCTAssertEqual(report.rows.map(\.functionID), expected.items.map { $0.functionID.uuidString.lowercased() })
        // The report binds to exactly what the shared builder captured for the GUI.
        XCTAssertEqual(report.workspaceID, expected.context.workspaceID)
        XCTAssertEqual(report.binaryID, expected.context.binaryID)
        XCTAssertEqual(report.artifactUUID, expected.context.artifactUUID)
        XCTAssertEqual(report.analysisInputFingerprintSHA256, expected.context.analysisInputFingerprintSHA256)
        XCTAssertEqual(report.documentGeneration, expected.owner.documentGeneration)
        XCTAssertEqual(report.limits, expected.limits)
        XCTAssertTrue(String(decoding: text, as: UTF8.self)
            .hasPrefix("// MacScope pseudocode export — provider: Native, whole image"))

        // The stdout line: one JSON object with exactly these keys.
        let line = try NativeExportCLI.encode(summary)
        XCTAssertFalse(line.contains(UInt8(ascii: "\n")))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["text", "report", "counts", "textSHA256", "seconds"])
        XCTAssertEqual(object["text"] as? String, output.path)
        XCTAssertEqual(object["report"] as? String, reportURL.path)
        XCTAssertEqual(object["textSHA256"] as? String, report.textSHA256)
        XCTAssertEqual(object["counts"] as? [String: Int], report.counts)
        XCTAssertNotNil(object["seconds"] as? Double)
    }

    // MARK: - Fixtures

    private static func fixtureStore() throws -> WorkspaceStore {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        var binary = try XCTUnwrap(store.snapshot.binaries.first)
        binary.artifactIdentity = try MachOSliceArtifactIdentity(uuid: UUID(),
            rawCPUType: MachOConstants.cpuTypeARM64, rawCPUSubtype: 0,
            selectedSliceSHA256: String(repeating: "a", count: 64), selectedSliceByteCount: 4)
        store.snapshot.binaries = [binary]
        var analysis = try XCTUnwrap(store.focusedAnalysis)
        analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)
        store.snapshot.analysisBySlot[binary.slot] = analysis
        return store
    }

    /// Every function exports a small native document except the last, which has no document.
    private static func respond(store: WorkspaceStore) throws
        -> @Sendable (UUID, ImageSlot) async throws -> NativeDecompilerValidatedExecution {
        let slot = store.focusedImageSlot
        let binary = try XCTUnwrap(store.snapshot.binary(in: slot))
        let analysis = try XCTUnwrap(store.snapshot.analysis(in: slot))
        let artifactUUID = try XCTUnwrap(binary.artifactIdentity?.uuid)
        let fingerprint = try XCTUnwrap(analysis.analysisInputFingerprint?.overallSHA256)
        let addresses = Dictionary(uniqueKeysWithValues: analysis.functions.map { ($0.id, $0.startAddress) })
        let last = analysis.functions.max { $0.startAddress == $1.startAddress
            ? $0.id.uuidString < $1.id.uuidString : $0.startAddress < $1.startAddress }?.id
        return { functionID, imageSlot in
            let address = try XCTUnwrap(addresses[functionID])
            return execution(functionID: functionID, imageSlot: imageSlot, address: address,
                             artifactUUID: artifactUUID, fingerprint: fingerprint,
                             document: functionID != last)
        }
    }

    private nonisolated static func execution(functionID: UUID, imageSlot: ImageSlot, address: UInt64,
                                              artifactUUID: UUID, fingerprint: String,
                                              document: Bool) -> NativeDecompilerValidatedExecution {
        let requestSHA = String(repeating: "a", count: 64)
        let success = NativeDecompilerWireSuccess(
            availability: .init(
                available: true, reasonCode: "available",
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
                image: .init(imageID: "image:fixture", uuid: artifactUUID, preferredLoadAddress: .init(0x1000)),
                function: .init(functionID: functionID.uuidString.lowercased(), name: "f",
                                entryAddress: .init(address), endAddressExclusive: .init(address + 4)),
                addressSpaces: [], types: [], instructions: [], varnodes: [], operations: [], blocks: [],
                edges: [], ssaValues: [], ssaBindings: [], phis: [], memoryVersions: [], memoryPhis: [],
                memoryEffects: [], variables: [], calls: [], regions: [], tokens: [],
                pseudocodeDocument: document ? .init(text: "void f(void) {}\n", language: "c", isComplete: true,
                                                     isTruncated: false) : nil,
                warnings: []))
        return NativeDecompilerValidatedExecution(
            requestSHA256: requestSHA, analysisInputFingerprintSHA256: fingerprint,
            imageSlot: imageSlot, functionID: functionID, success: success, source: .validatedCache)
    }
}

/// A scripted stand-in for the registry's batch capture.
private struct RecordingDecompiler: NativePseudocodeBatchDecompiling {
    let ledger = Ledger()
    let respond: @Sendable (UUID, ImageSlot) async throws -> NativeDecompilerValidatedExecution

    func beginBatchExport(snapshot: WorkspaceSnapshot, imageSlot: ImageSlot) async throws
        -> any NativePseudocodeBatchSession {
        ledger.bump(\.begins)
        return Session(imageSlot: imageSlot, ledger: ledger, respond: respond)
    }

    private struct Session: NativePseudocodeBatchSession {
        let imageSlot: ImageSlot
        let ledger: Ledger
        let respond: @Sendable (UUID, ImageSlot) async throws -> NativeDecompilerValidatedExecution

        func decompile(functionID: UUID) async throws -> NativeDecompilerValidatedExecution {
            ledger.bump(\.decompiles)
            return try await respond(functionID, imageSlot)
        }

        func cancel() {}
        func retire() async { ledger.bump(\.retires) }
    }
}

private final class Ledger: @unchecked Sendable {
    struct Counts { var begins = 0, decompiles = 0, retires = 0 }
    private let lock = NSLock()
    private var counts = Counts()
    func bump(_ key: WritableKeyPath<Counts, Int>) { lock.withLock { counts[keyPath: key] += 1 } }
    var begins: Int { lock.withLock { counts.begins } }
    var decompiles: Int { lock.withLock { counts.decompiles } }
    var retires: Int { lock.withLock { counts.retires } }
}
