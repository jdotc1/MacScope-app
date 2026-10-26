import Foundation
import XCTest
@testable import MacScope

final class WorkspaceInstructionSidecarPackageTests: XCTestCase {
    func testNewSaveWritesSlimVersion4AndRestoresEveryInstructionField() throws {
        for version in [1, 2] {
            let fixture = fixture(version: version)
            try withPackage { url in
                try MacScopeDocumentPackage.writePackage(fixture.manifest, attachmentsByBinaryID: fixture.attachments, to: url)
                let opened = try MacScopeDocumentPackage.openPackage(from: url)
                XCTAssertEqual(opened.manifest.formatVersion, 4)
                XCTAssertEqual(opened.manifest.analysisFormatVersion, version)
                XCTAssertEqual(opened.manifest.analysis?.instructions ?? [], [])
                XCTAssertTrue((opened.manifest.imageAnalyses ?? []).allSatisfy { $0.analysis.instructions.isEmpty })
                XCTAssertEqual(opened.snapshot.analysis(in: fixture.slot)?.instructions, fixture.rows)
                XCTAssertEqual(opened.snapshot.analysis(in: fixture.slot)?.controlFlowEdges,
                               fixture.manifest.analysisFormatVersion == 1 ? fixture.manifest.analysis?.controlFlowEdges
                               : fixture.manifest.imageAnalyses?.first?.analysis.controlFlowEdges)
                XCTAssertEqual(opened.manifest.analysis?.controlFlowEdges ?? [], [])
                let expectedBlocks = fixture.manifest.analysisFormatVersion == 1
                    ? fixture.manifest.analysis?.basicBlocks : fixture.manifest.imageAnalyses?.first?.analysis.basicBlocks
                XCTAssertEqual(opened.snapshot.analysis(in: fixture.slot)?.basicBlocks, expectedBlocks)
                XCTAssertEqual(opened.manifest.analysis?.basicBlocks ?? [], [])
                XCTAssertTrue((opened.manifest.imageAnalyses ?? []).allSatisfy { $0.analysis.basicBlocks.isEmpty })
                XCTAssertEqual(opened.manifest.instructionSidecar?.groups[0].basicBlockCount,
                               UInt64(expectedBlocks?.count ?? 0))
                XCTAssertEqual(opened.attachmentsByBinaryID, fixture.attachments)
                let descriptor = try XCTUnwrap(opened.manifest.instructionSidecar)
                let data = try Data(contentsOf: url.appendingPathComponent(descriptor.path))
                XCTAssertEqual(descriptor.sha256, MacScopeDocumentPackage.fileHash(for: data))
                XCTAssertEqual(descriptor.byteCount, UInt64(data.count))
                XCTAssertEqual(opened.instructionSidecarData, data)
                // A validated v4 package can be copied without recreating the rows in JSON.
                let copy = url.deletingLastPathComponent().appendingPathComponent("copy.mscope")
                try MacScopeDocumentPackage.writePackage(
                    opened.manifest, attachmentsByBinaryID: opened.attachmentsByBinaryID, to: copy,
                    instructionSidecarData: data
                )
                XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent(descriptor.path)), data)
                XCTAssertEqual(try MacScopeDocumentPackage.openPackage(from: copy).snapshot.analysis(in: fixture.slot)?.instructions,
                               fixture.rows)
            }
        }
    }

    func testAdmittedSidecarSharesOnlyCanonicalGenerationMemosAndMutationInvalidates() throws {
        let fixture = fixture(version: 2)
        try withPackage { url in
            try MacScopeDocumentPackage.writePackage(fixture.manifest, attachmentsByBinaryID: fixture.attachments, to: url)
            try WorkspaceManifestDecodeScope.ensuring { scope in
                let opened = try MacScopeDocumentPackage.openPackage(from: url)
                let descriptor = try XCTUnwrap(opened.manifest.instructionSidecar)
                let data = try XCTUnwrap(opened.instructionSidecarData)
                let group = try XCTUnwrap(scope.instructionGroups(for: data, descriptor: descriptor)?.first)
                var analysis = try XCTUnwrap(opened.snapshot.analysis(in: fixture.slot))
                let binary = try XCTUnwrap(opened.snapshot.binaries.first)
                XCTAssertTrue(analysis.instructionFingerprintMemo === group.instructionFingerprintMemo)
                XCTAssertTrue(analysis.controlFlowFingerprintMemo === group.controlFlowFingerprintMemo)
                let fingerprint = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)
                let cached = try group.instructionFingerprintMemo.value { throw NSError(domain: "unexpected-rebuild", code: 1) }
                XCTAssertEqual(cached, try XCTUnwrap(fingerprint.facets.first { $0.kind == .decodedInstructions }))
                analysis.instructions[0].operands += " changed"
                XCTAssertFalse(analysis.instructionFingerprintMemo === group.instructionFingerprintMemo)
                let mutated = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)
                XCTAssertNotEqual(try XCTUnwrap(mutated.facets.first { $0.kind == .decodedInstructions }), cached)
            }
        }
    }

    func testLegacyInlineInstructionsStillOpenAndMigrateOnlyOnSave() throws {
        for version in [1, 2] {
            let fixture = fixture(version: version)
            try withPackage { url in
                try writeLegacy(fixture, to: url)
                let before = try Data(contentsOf: MacScopeDocumentPackage.manifestURL(in: url))
                let opened = try MacScopeDocumentPackage.openPackage(from: url)
                XCTAssertEqual(opened.manifest.formatVersion, version)
                XCTAssertEqual(opened.snapshot.analysis(in: fixture.slot)?.instructions, fixture.rows)
                XCTAssertNil(opened.instructionSidecarData)
                let expectedBlocks = fixture.manifest.analysisFormatVersion == 1
                    ? fixture.manifest.analysis?.basicBlocks : fixture.manifest.imageAnalyses?.first?.analysis.basicBlocks
                XCTAssertEqual(opened.snapshot.analysis(in: fixture.slot)?.basicBlocks, expectedBlocks)
                XCTAssertEqual(try Data(contentsOf: MacScopeDocumentPackage.manifestURL(in: url)), before)
                let migrated = url.deletingLastPathComponent().appendingPathComponent("migrated.mscope")
                try MacScopeDocumentPackage.writePackage(opened.manifest, attachmentsByBinaryID: opened.attachmentsByBinaryID, to: migrated)
                XCTAssertEqual(try MacScopeDocumentPackage.readManifest(from: migrated).formatVersion, 4)
                XCTAssertEqual(try MacScopeDocumentPackage.openPackage(from: migrated).snapshot.analysis(in: fixture.slot)?.instructions,
                               fixture.rows)
                XCTAssertEqual(try MacScopeDocumentPackage.openPackage(from: migrated).snapshot.analysis(in: fixture.slot)?.basicBlocks,
                               expectedBlocks)
            }
        }
    }

    func testLegacyVersion3ReconstructionStillOpensWithInlineInstructions() throws {
        let reconstruction = try ReconstructionPackageFixture.make()
        defer { reconstruction.remove() }
        var legacy = reconstruction.manifest
        let sample = fixture()
        legacy.analysis = sample.manifest.analysis
        // Create the real reconstruction tree, then explicitly serialize the old format.
        try MacScopeDocumentPackage.writePackage(
            legacy, attachmentsByBinaryID: [reconstruction.binaryID: reconstruction.binaryBytes],
            reconstructionState: reconstruction.state, reconstructionAttachmentSources: [reconstruction.source],
            to: reconstruction.packageURL
        )
        let prepared = try MacScopeDocumentPackage.preparedManifest(legacy, reconstructionState: reconstruction.state)
        XCTAssertEqual(prepared.formatVersion, 3)
        try MacScopeDocumentPackage.writeManifest(prepared, to: reconstruction.packageURL)
        try FileManager.default.removeItem(at: reconstruction.packageURL.appendingPathComponent(WorkspaceInstructionSidecarCodec.fileName))
        let opened = try MacScopeDocumentPackage.openPackage(from: reconstruction.packageURL)
        XCTAssertEqual(opened.manifest.formatVersion, 3)
        XCTAssertEqual(opened.reconstructionState, reconstruction.state)
        XCTAssertEqual(opened.snapshot.instructions, sample.rows)
    }

    func testMissingChangedTruncatedAndUndeclaredSidecarsFailAdmission() throws {
        let fixture = fixture()
        let storage = try MacScopeDocumentPackage.preparedInstructionStorage(fixture.manifest)
        let manifestData = try MacScopeDocumentPackage.encodedManifest(storage.manifest)
        for bytes in [nil, Data(storage.data.dropLast()), Data(repeating: 0, count: storage.data.count)] as [Data?] {
            XCTAssertThrowsError(try MacScopeDocumentPackage.validatedContents(
                manifestData: manifestData, attachmentsByBinaryID: fixture.attachments,
                instructionSidecarData: bytes
            ))
        }
        XCTAssertThrowsError(try MacScopeDocumentPackage.validatedContents(
            manifestData: MacScopeDocumentPackage.encodedManifest(fixture.manifest),
            attachmentsByBinaryID: fixture.attachments, instructionSidecarData: storage.data
        ))
        try withPackage { url in
            try MacScopeDocumentPackage.writePackage(fixture.manifest, attachmentsByBinaryID: fixture.attachments, to: url)
            try FileManager.default.removeItem(at: url.appendingPathComponent(WorkspaceInstructionSidecarCodec.fileName))
            XCTAssertThrowsError(try MacScopeDocumentPackage.openPackage(from: url))
        }
    }

    func testVersion4RejectsDuplicateKeysAndMixedInstructionAuthority() throws {
        let fixture = fixture()
        let storage = try MacScopeDocumentPackage.preparedInstructionStorage(fixture.manifest)
        let encoded = try MacScopeDocumentPackage.encodedManifest(storage.manifest)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let duplicateRoot = String(json.dropLast()) + ",\"formatVersion\":1}"
        XCTAssertThrowsError(try MacScopeDocumentPackage.validatedManifest(manifestData: Data(duplicateRoot.utf8)))
        let duplicateDescriptor = json.replacingOccurrences(of: "\"byteCount\" :", with: "\"byteCount\" : 0, \"byteCount\" :")
        XCTAssertNotEqual(duplicateDescriptor, json)
        XCTAssertThrowsError(try MacScopeDocumentPackage.validatedManifest(manifestData: Data(duplicateDescriptor.utf8)))
        var mixed = storage.manifest
        mixed.analysis?.instructions = fixture.rows
        XCTAssertThrowsError(try MacScopeDocumentPackage.validatedManifest(manifestData: MacScopeDocumentPackage.encodedManifest(mixed)))
        var badPath = storage.manifest
        badPath.instructionSidecar?.path = "../instructions.bin"
        XCTAssertThrowsError(try MacScopeDocumentPackage.validatedManifest(manifestData: MacScopeDocumentPackage.encodedManifest(badPath)))
        var badCount = storage.manifest
        badCount.instructionSidecar?.groups[0].rowCount = UInt64.max
        XCTAssertThrowsError(try MacScopeDocumentPackage.validatedManifest(manifestData: MacScopeDocumentPackage.encodedManifest(badCount)))
    }

    func testProbeCapsManifestAndSidecarIndependentlyAndBindsSidecarChanges() async throws {
        let fixture = fixture(wide: true)
        try await withPackage { url in
            try MacScopeDocumentPackage.writePackage(fixture.manifest, attachmentsByBinaryID: fixture.attachments, to: url)
            let manifestData = try Data(contentsOf: MacScopeDocumentPackage.manifestURL(in: url))
            let sidecarURL = url.appendingPathComponent(WorkspaceInstructionSidecarCodec.fileName)
            let bytes = try Data(contentsOf: sidecarURL)
            XCTAssertGreaterThan(bytes.count, manifestData.count)
            let probe = WorkspacePackageVersionProbe(limits: .init(maximumManifestCaptureBytes: UInt64(manifestData.count)))
            let before = try await probe.observe(url)
            XCTAssertEqual(before.condition, .valid)
            let capped = try await WorkspacePackageVersionProbe(limits: .init(maximumInstructionSidecarCaptureBytes: 1)).observe(url)
            XCTAssertEqual(capped.condition, .invalid)
            XCTAssertEqual(capped.boundedReason, "package-instruction-sidecar-size-or-file-invalid")
            var changed = bytes
            changed[changed.count - 1] ^= 1
            try changed.write(to: sidecarURL)
            let after = try await probe.observe(url)
            XCTAssertEqual(after.condition, .invalid)
            XCTAssertNotEqual(before.observationSHA256, after.observationSHA256)
        }
    }

    func testProbeAndDirectOpenRejectSidecarLinks() async throws {
        let fixture = fixture()
        for symbolic in [true, false] {
            try await withPackage { url in
                try MacScopeDocumentPackage.writePackage(fixture.manifest, attachmentsByBinaryID: fixture.attachments, to: url)
                let sidecar = url.appendingPathComponent(WorkspaceInstructionSidecarCodec.fileName)
                let outside = url.deletingLastPathComponent().appendingPathComponent("outside.bin")
                try FileManager.default.moveItem(at: sidecar, to: outside)
                if symbolic {
                    try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: outside)
                } else {
                    try FileManager.default.linkItem(at: outside, to: sidecar)
                }
                XCTAssertThrowsError(try MacScopeDocumentPackage.openPackage(from: url))
                let observed = try await WorkspacePackageVersionProbe().observe(url)
                XCTAssertEqual(observed.condition, .invalid)
            }
        }
    }

    func testStagedSidecarMutationCannotPublish() async throws {
        let fixture = fixture()
        try await withPackage { url in
            let storage = try MacScopeDocumentPackage.preparedInstructionStorage(fixture.manifest)
            let payload = WorkspaceDocumentPackagePayload(
                documentID: fixture.manifest.documentID, workspaceID: fixture.manifest.workspaceUUID,
                manifestData: try MacScopeDocumentPackage.encodedManifest(storage.manifest),
                attachmentsByBinaryID: fixture.attachments, instructionSidecarData: storage.data,
                capturedMutationGeneration: .init(rawValue: 1)
            )
            let publisher = WorkspaceDocumentPublisher()
            let staged = try await publisher.stage(payload, in: url.deletingLastPathComponent())
            let sidecar = staged.stagingURL.appendingPathComponent(WorkspaceInstructionSidecarCodec.fileName)
            var bytes = try Data(contentsOf: sidecar)
            bytes[bytes.count - 1] ^= 1
            try bytes.write(to: sidecar)
            let destination = try await WorkspacePackageVersionProbe().observe(url)
            do {
                _ = try await publisher.publish(staged, to: destination.location, expecting: destination)
                XCTFail("A changed sidecar must never publish")
            } catch { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testOldVersion4InlineControlFlowMigratesOnlyOnSave() throws {
        let fixture = fixture()
        let edges = try XCTUnwrap(fixture.manifest.analysis?.controlFlowEdges)
        var instructionsOnly = fixture.manifest
        instructionsOnly.analysis?.controlFlowEdges = []
        instructionsOnly.analysis?.basicBlocks = []
        let oldStorage = try MacScopeDocumentPackage.preparedInstructionStorage(instructionsOnly)
        var oldManifest = oldStorage.manifest
        oldManifest.analysis?.controlFlowEdges = edges
        try withPackage { url in
            try MacScopeDocumentPackage.writeManifest(oldManifest, to: url)
            try oldStorage.data.write(to: url.appendingPathComponent("instructions.bin"))
            for binary in oldManifest.binaries {
                try XCTUnwrap(fixture.attachments[binary.id]).write(to: MacScopeDocumentPackage.attachmentURL(
                    in: url, relativePath: binary.attachmentRelativePath))
            }
            let opened = try MacScopeDocumentPackage.openPackage(from: url)
            XCTAssertNil(opened.manifest.instructionSidecar?.groups[0].controlFlowEdgeCount)
            XCTAssertEqual(opened.snapshot.controlFlowEdges, edges)
            let copy = url.deletingLastPathComponent().appendingPathComponent("migrated-flow.mscope")
            try MacScopeDocumentPackage.writePackage(opened.manifest,
                attachmentsByBinaryID: opened.attachmentsByBinaryID, to: copy,
                instructionSidecarData: opened.instructionSidecarData)
            let migrated = try MacScopeDocumentPackage.openPackage(from: copy)
            XCTAssertEqual(migrated.manifest.instructionSidecar?.groups[0].controlFlowEdgeCount, UInt64(edges.count))
            XCTAssertEqual(migrated.snapshot.controlFlowEdges, edges)
            XCTAssertEqual(migrated.snapshot.instructions, fixture.rows)
            XCTAssertNil(try MacScopeDocumentPackage.readManifest(from: url).instructionSidecar?.groups[0].controlFlowEdgeCount)
        }
    }

    func testControlFlowDescriptorRejectsMixedRowsAndOverLimitCount() throws {
        let storage = try MacScopeDocumentPackage.preparedInstructionStorage(fixture().manifest)
        var mixed = storage.manifest
        mixed.analysis?.controlFlowEdges = [ControlFlowEdge(id: UUID(), from: 1, to: 2, kind: "branch")]
        XCTAssertThrowsError(try MacScopeDocumentPackage.validateInstructionSidecarDescriptor(mixed))
        var count = storage.manifest
        count.instructionSidecar?.groups[0].controlFlowEdgeCount = UInt64.max
        XCTAssertThrowsError(try MacScopeDocumentPackage.validateInstructionSidecarDescriptor(count))
        var missing = storage.manifest
        missing.instructionSidecar?.groups[0].controlFlowEdgeCount = nil
        XCTAssertThrowsError(try MacScopeDocumentPackage.validatedInstructionGroups(missing, data: storage.data))
    }

    func testOldVersion4InlineBlocksMigrateOnlyOnSaveFromBothCodecs() throws {
        for version in [1, 2] {
            for codecVersion in [1, 2] {
                let fixture = fixture(version: version)
                let source = version == 1 ? fixture.manifest.analysis! : fixture.manifest.imageAnalyses![0].analysis
                var prior = fixture.manifest
                if version == 1 {
                    prior.analysis?.basicBlocks = []
                    if codecVersion == 1 { prior.analysis?.controlFlowEdges = [] }
                } else {
                    prior.imageAnalyses?[0].analysis.basicBlocks = []
                    if codecVersion == 1 { prior.imageAnalyses?[0].analysis.controlFlowEdges = [] }
                }
                let oldStorage = try MacScopeDocumentPackage.preparedInstructionStorage(prior)
                XCTAssertEqual(oldStorage.data[6], UInt8(codecVersion))
                var oldManifest = oldStorage.manifest
                if version == 1 { oldManifest.analysis?.basicBlocks = source.basicBlocks }
                else { oldManifest.imageAnalyses?[0].analysis.basicBlocks = source.basicBlocks }
                try withPackage { url in
                    try MacScopeDocumentPackage.writeManifest(oldManifest, to: url)
                    try oldStorage.data.write(to: url.appendingPathComponent("instructions.bin"))
                    for binary in oldManifest.binaries {
                        try XCTUnwrap(fixture.attachments[binary.id]).write(to: MacScopeDocumentPackage.attachmentURL(
                            in: url, relativePath: binary.attachmentRelativePath))
                    }
                    let manifestBefore = try Data(contentsOf: MacScopeDocumentPackage.manifestURL(in: url))
                    let opened = try MacScopeDocumentPackage.openPackage(from: url)
                    XCTAssertNil(opened.manifest.instructionSidecar?.groups[0].basicBlockCount)
                    XCTAssertEqual(opened.snapshot.analysis(in: fixture.slot)?.basicBlocks, source.basicBlocks)
                    XCTAssertEqual(try Data(contentsOf: MacScopeDocumentPackage.manifestURL(in: url)), manifestBefore)
                    XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("instructions.bin")), oldStorage.data)
                    let saved = url.deletingLastPathComponent().appendingPathComponent("blocks.mscope")
                    try MacScopeDocumentPackage.writePackage(opened.manifest,
                        attachmentsByBinaryID: opened.attachmentsByBinaryID, to: saved,
                        instructionSidecarData: opened.instructionSidecarData)
                    let migrated = try MacScopeDocumentPackage.openPackage(from: saved)
                    XCTAssertEqual(migrated.instructionSidecarData?[6], 3)
                    XCTAssertEqual(migrated.manifest.instructionSidecar?.groups[0].basicBlockCount, UInt64(source.basicBlocks.count))
                    XCTAssertEqual(migrated.snapshot.analysis(in: fixture.slot)?.basicBlocks, source.basicBlocks)
                    XCTAssertEqual(migrated.snapshot.analysis(in: fixture.slot)?.instructions, source.instructions)
                    XCTAssertEqual(migrated.snapshot.analysis(in: fixture.slot)?.controlFlowEdges,
                                   codecVersion == 1 ? [] : source.controlFlowEdges)
                }
            }
        }
    }

    func testBasicBlockDescriptorRejectsMixedRowsAndOverLimitCount() throws {
        let fixture = fixture()
        let storage = try MacScopeDocumentPackage.preparedInstructionStorage(fixture.manifest)
        var mixed = storage.manifest
        mixed.analysis?.basicBlocks = fixture.manifest.analysis!.basicBlocks
        XCTAssertThrowsError(try MacScopeDocumentPackage.validateInstructionSidecarDescriptor(mixed))
        var count = storage.manifest
        count.instructionSidecar?.groups[0].basicBlockCount = UInt64.max
        XCTAssertThrowsError(try MacScopeDocumentPackage.validateInstructionSidecarDescriptor(count))
        var missing = storage.manifest
        missing.instructionSidecar?.groups[0].basicBlockCount = nil
        XCTAssertThrowsError(try MacScopeDocumentPackage.validatedInstructionGroups(missing, data: storage.data))
        var noFlowCount = storage.manifest
        noFlowCount.instructionSidecar?.groups[0].controlFlowEdgeCount = nil
        XCTAssertThrowsError(try MacScopeDocumentPackage.validateInstructionSidecarDescriptor(noFlowCount))
    }

    private struct Fixture {
        let manifest: WorkspacePackageManifest
        let attachments: [UUID: Data]
        let slot: ImageSlot
        let rows: [InstructionRow]
    }

    private func fixture(version: Int = 1, wide: Bool = false) -> Fixture {
        let id = UUID(uuidString: "56780000-0000-0000-0000-000000000001")!
        let slot = version == 1 ? ImageSlot.primary : ImageSlot(rawValue: 1)
        let bytes = Data([0x1f, 0x20, 0x03, 0xd5, 0xc0, 0x03, 0x5f, 0xd6])
        let rows = [
            InstructionRow(address: 0x1000, bytes: "1f 20 03 d5", mnemonic: "nop", operands: wide ? String(repeating: "λ", count: 8192) : "α", hasBreakpoint: true, comment: nil),
            InstructionRow(address: 0x1004, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: "")
        ]
        let functionID = UUID()
        let analysis = WorkspacePackageAnalysis(functions: [.init(id: functionID, name: "fixture", startAddress: 0x1000, endAddress: 0x1008, confidence: 1)], basicBlocks: [
            BasicBlockSummary(id: UUID(), functionID: functionID, startAddress: 0x1000, endAddress: 0x1008, instructionCount: 2)
        ], instructions: rows, controlFlowEdges: [
            ControlFlowEdge(id: UUID(), from: 0x1000, to: 0x1004, kind: "fallthrough"),
            ControlFlowEdge(id: UUID(), from: 0x1004, to: UInt64.max, kind: "custom λ")
        ])
        let binary = WorkspacePackageBinary(
            id: id, displayName: "fixture", originalPath: "/fixture.bin",
            attachmentRelativePath: MacScopeDocumentPackage.attachmentRelativePath(for: id, originalPath: "/fixture.bin"),
            kind: "Raw data", architecture: "arm64", fileHash: MacScopeDocumentPackage.fileHash(for: bytes),
            fileSize: Int64(bytes.count), slot: slot
        )
        return Fixture(manifest: WorkspacePackageManifest(
            formatVersion: version, documentID: UUID(), workspaceUUID: UUID(), workspaceName: "Sidecar fixture",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            binaries: [binary], analysis: version == 1 ? analysis : WorkspacePackageAnalysis(),
            imageAnalyses: version == 1 ? nil : [.init(binaryID: id, imageSlot: slot, analysis: analysis)], session: nil
        ), attachments: [id: bytes], slot: slot, rows: rows)
    }

    private func writeLegacy(_ fixture: Fixture, to url: URL) throws {
        try MacScopeDocumentPackage.writeManifest(fixture.manifest, to: url)
        for binary in fixture.manifest.binaries {
            try XCTUnwrap(fixture.attachments[binary.id]).write(to: MacScopeDocumentPackage.attachmentURL(in: url, relativePath: binary.attachmentRelativePath))
        }
    }

    private func withPackage(_ body: (URL) throws -> Void) throws {
        let root = TestWorkRoot.scratchURL("MacScopeDevLoop.noindex")
            .appendingPathComponent("t1-package-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("fixture.mscope"))
    }

    private func withPackage(_ body: (URL) async throws -> Void) async throws {
        let root = TestWorkRoot.scratchURL("MacScopeDevLoop.noindex")
            .appendingPathComponent("t1-package-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root.appendingPathComponent("fixture.mscope"))
    }
}
