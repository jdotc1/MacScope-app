import Foundation
import XCTest
@testable import MacScope

final class WorkspaceInstructionSidecarScaleTests: XCTestCase {
    /// Single-sample measurement, explicitly requested for T1. Never use XCTest.measure here.
    func testVimScaleSidecarSaveOpenPreservesAllRows() throws {
        try measureSaveOpen(label: "sidecar")
    }

    /// T22's sole before/after sample; selected explicitly, never XCTest.measure.
    func testT22HeadlessLoadHotspotsSingleSample() throws {
        let count = 60_000
        let rows = (0..<count).map { index in
            InstructionRow(address: 0x1000 + UInt64(index) * 4, bytes: "1f 20 03 d5",
                           mnemonic: index.isMultiple(of: 8) ? "unknown" : "nop", operands: "", hasBreakpoint: false, comment: nil)
        }
        let data = Data(repeating: 0, count: count * 4)
        let id = UUID(uuidString: "12340000-0000-0000-0000-000000000022")!
        let binary = WorkspacePackageBinary(id: id, displayName: "T22 synthetic", originalPath: "/fixtures/t22.bin",
            attachmentRelativePath: MacScopeDocumentPackage.attachmentRelativePath(for: id, originalPath: "/fixtures/t22.bin"),
            kind: "Raw data", architecture: "arm64", fileHash: MacScopeDocumentPackage.fileHash(for: data), fileSize: Int64(data.count))
        let manifest = WorkspacePackageManifest(documentID: UUID(), workspaceUUID: UUID(), workspaceName: "T22",
            createdAt: Date(), modifiedAt: Date(), binaries: [binary],
            analysis: WorkspacePackageAnalysis(instructions: rows), session: nil)
        let root = TestWorkRoot.scratchURL("lane22-evidence")
            .appendingPathComponent("sample-\(UUID().uuidString).mscope")
        defer { try? FileManager.default.removeItem(at: root) }
        try MacScopeDocumentPackage.writePackage(manifest, attachmentsByBinaryID: [id: data], to: root)
        let start = ContinuousClock.now
        let opened = try MacScopeDocumentPackage.openPackage(from: root)
        let read = ContinuousClock.now
        var analysis = try XCTUnwrap(opened.snapshot.analysis(in: .primary))
        analysis.sections = [SectionSummary(id: UUID(), name: "__text", address: 0x1000, size: UInt64(data.count), fileOffset: 0, isExecutable: true)]
        let fingerprint = try AnalysisFingerprintBuilder.fingerprint(binary: XCTUnwrap(opened.snapshot.binaries.first), analysis: analysis)
        let fingerprinted = ContinuousClock.now
        let diagnostics = AnalysisDiagnosticsCollector().collect(.init(instructions: analysis.instructions,
            controlFlowEdges: analysis.controlFlowEdges, xrefs: analysis.xrefs, sections: analysis.sections))
        let end = ContinuousClock.now
        XCTAssertEqual(analysis.instructions.count, count)
        XCTAssertEqual(diagnostics.count, AnalysisDiagnosticsCollector.maximumDiagnosticCount)
        XCTAssertEqual(try XCTUnwrap(fingerprint.facets.first { $0.kind == .decodedInstructions }).sha256,
                       "8fda139a0d5456782f1c2e896838edf4cbc7ff3dbb7ed0210a8ce7c5e775dfe9")
        print("T22_LOAD rows=\(count) open=\(start.duration(to: read)) fingerprint=\(read.duration(to: fingerprinted)) diagnostics=\(fingerprinted.duration(to: end)) total=\(start.duration(to: end)) instructionSHA=\(try XCTUnwrap(fingerprint.facets.first { $0.kind == .decodedInstructions }).sha256)")
    }

    /// Lane AL's sole before/after cold-fingerprint sample on the T22 fixture (60,000 rows,
    /// opened through the sidecar package path); selected explicitly, never XCTest.measure.
    func testALColdFingerprintBreakdownSingleSample() throws {
        let count = 60_000
        let rows = (0..<count).map { index in
            InstructionRow(address: 0x1000 + UInt64(index) * 4, bytes: "1f 20 03 d5",
                           mnemonic: index.isMultiple(of: 8) ? "unknown" : "nop", operands: "", hasBreakpoint: false, comment: nil)
        }
        let data = Data(repeating: 0, count: count * 4)
        let id = UUID(uuidString: "12340000-0000-0000-0000-000000000022")!
        let binary = WorkspacePackageBinary(id: id, displayName: "T22 synthetic", originalPath: "/fixtures/t22.bin",
            attachmentRelativePath: MacScopeDocumentPackage.attachmentRelativePath(for: id, originalPath: "/fixtures/t22.bin"),
            kind: "Raw data", architecture: "arm64", fileHash: MacScopeDocumentPackage.fileHash(for: data), fileSize: Int64(data.count))
        let manifest = WorkspacePackageManifest(documentID: UUID(), workspaceUUID: UUID(), workspaceName: "T22",
            createdAt: Date(), modifiedAt: Date(), binaries: [binary],
            analysis: WorkspacePackageAnalysis(instructions: rows), session: nil)
        let root = TestWorkRoot.scratchURL("MacScopeDevLoop.noindex")
            .appendingPathComponent("al-cold-\(UUID().uuidString).mscope")
        defer { try? FileManager.default.removeItem(at: root) }
        try MacScopeDocumentPackage.writePackage(manifest, attachmentsByBinaryID: [id: data], to: root)
        let opened = try MacScopeDocumentPackage.openPackage(from: root)
        var analysis = try XCTUnwrap(opened.snapshot.analysis(in: .primary))
        analysis.sections = [SectionSummary(id: UUID(), name: "__text", address: 0x1000, size: UInt64(data.count), fileOffset: 0, isExecutable: true)]
        let image = try XCTUnwrap(opened.snapshot.binaries.first)
        let expected = "8fda139a0d5456782f1c2e896838edf4cbc7ff3dbb7ed0210a8ce7c5e775dfe9"

        // 1. The T22 stage: first (cold-memo) fingerprint of the opened image.
        let t0 = ContinuousClock.now
        let cold = try AnalysisFingerprintBuilder.fingerprint(binary: image, analysis: analysis)
        let t1 = ContinuousClock.now
        let warm = try AnalysisFingerprintBuilder.fingerprint(binary: image, analysis: analysis)
        let t2 = ContinuousClock.now
        XCTAssertEqual(cold, warm)
        XCTAssertEqual(try XCTUnwrap(cold.facets.first { $0.kind == .decodedInstructions }).sha256, expected)

        // 2. Breakdown. Everything except the instruction facet (fresh memos, no rows):
        var rest = analysis
        rest.instructions = []
        let r0 = ContinuousClock.now
        _ = try AnalysisFingerprintBuilder.fingerprint(binary: image, analysis: rest)
        let r1 = ContinuousClock.now
        _ = AnalysisFingerprintBuilder.sha256Hex(analysis.imageBytes)
        let r2 = ContinuousClock.now
        // The instruction facet's stages, reproduced with the production canonical writer.
        let source = analysis.instructions
        let s0 = ContinuousClock.now
        let sorted = source.sorted { $0.address < $1.address }
        let s1 = ContinuousClock.now
        var writer = AnalysisFingerprintCanonicalWriter()
        for row in sorted {
            writer.beginRecord("instruction")
            writer.field("address", row.address)
            writer.field("bytes", row.bytes)
            writer.field("mnemonic", row.mnemonic)
            writer.field("operands", row.operands)
            writer.endRecord("instruction")
        }
        let s2 = ContinuousClock.now
        let digest = writer.digestHex()
        let s3 = ContinuousClock.now
        XCTAssertEqual(digest, expected)
        print("AL_COLD rows=\(count) coldFingerprint=\(t0.duration(to: t1)) warmFingerprint=\(t1.duration(to: t2)) "
            + "nonInstructionFacets=\(r0.duration(to: r1)) imageSHA=\(r1.duration(to: r2)) "
            + "instructionSort=\(s0.duration(to: s1)) instructionEncode=\(s1.duration(to: s2)) "
            + "instructionDigest=\(s2.duration(to: s3))")
    }

    private func measureSaveOpen(label: String) throws {
        let count = 590_883
        let rows = (0..<count).map { index in
            InstructionRow(
                address: 0x1000 + UInt64(index) * 4, bytes: "1f 20 03 d5",
                mnemonic: index % 3 == 0 ? "add" : "nop",
                operands: index % 3 == 0 ? "x0, x1, #\(index % 4096)" : "",
                hasBreakpoint: index % 100_000 == 0,
                comment: index % 8192 == 0 ? "row \(index): α" : nil
            )
        }
        let data = Data(repeating: 0, count: count * 4)
        let binaryID = UUID(uuidString: "12340000-0000-0000-0000-000000000001")!
        let binary = WorkspacePackageBinary(
            id: binaryID, displayName: "Synthetic vim-scale", originalPath: "/fixtures/synthetic.bin",
            attachmentRelativePath: MacScopeDocumentPackage.attachmentRelativePath(
                for: binaryID, originalPath: "/fixtures/synthetic.bin"
            ), kind: "Raw data", architecture: "arm64",
            fileHash: MacScopeDocumentPackage.fileHash(for: data), fileSize: Int64(data.count)
        )
        let manifest = WorkspacePackageManifest(
            documentID: UUID(uuidString: "12340000-0000-0000-0000-000000000002")!,
            workspaceUUID: UUID(uuidString: "12340000-0000-0000-0000-000000000003")!,
            workspaceName: "Synthetic vim-scale", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000), binaries: [binary],
            analysis: WorkspacePackageAnalysis(functions: [FunctionSummary(
                id: UUID(uuidString: "12340000-0000-0000-0000-000000000004")!, name: "fixture",
                startAddress: 0x1000, endAddress: 0x1000 + UInt64(count) * 4, confidence: 1
            )], instructions: rows), session: nil
        )
        let root = TestWorkRoot.scratchURL("MacScopeDevLoop.noindex")
            .appendingPathComponent("t1-scale-\(label)-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("Synthetic.mscope", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = ContinuousClock.now
        try MacScopeDocumentPackage.writePackage(manifest, attachmentsByBinaryID: [binaryID: data], to: package)
        let saved = ContinuousClock.now
        let opened = try MacScopeDocumentPackage.openPackage(from: package)
        let read = ContinuousClock.now
        XCTAssertEqual(opened.manifest.formatVersion, 4)
        XCTAssertEqual(opened.snapshot.instructions, rows)
        XCTAssertEqual(opened.attachmentsByBinaryID[binaryID], data)
        let manifestSize = try FileManager.default.attributesOfItem(
            atPath: MacScopeDocumentPackage.manifestURL(in: package).path
        )[.size] as? Int ?? 0
        let sidecar = package.appendingPathComponent("instructions.bin")
        let sidecarSize = (try? FileManager.default.attributesOfItem(atPath: sidecar.path)[.size] as? Int) ?? 0
        XCTAssertLessThan(manifestSize, 16_384)
        XCTAssertGreaterThan(sidecarSize, 0)
        print("T1_SCALE label=\(label) rows=\(count) save=\(start.duration(to: saved)) open=\(saved.duration(to: read)) manifestBytes=\(manifestSize) sidecarBytes=\(sidecarSize)")
    }
}
