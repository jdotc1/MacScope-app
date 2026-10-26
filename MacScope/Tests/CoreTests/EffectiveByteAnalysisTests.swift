import Foundation
import XCTest
@testable import MacScope

/// Product-seam regressions: real decoders consume one overlaid byte stream;
/// table readers, reload and exports share those bytes without altering the artifact.
final class EffectiveByteAnalysisTests: XCTestCase {
    private let base: UInt64 = 0x1000
    private let ignoredURL = URL(fileURLWithPath: "/effective-byte-fixture")

    func testInteriorX86EditPreservesTrailingBytesAndChangesDecodedImmediate() throws {
        let raw = Data([0xb8, 1, 0, 0, 0, 0xc3])
        let snapshot = try analyze(raw, patches: [base + 1: BytePatch(bytes: [2])])
        XCTAssertEqual(snapshot.instructions.map(\.address), [base, base + 5])
        XCTAssertEqual(snapshot.instructions.first?.bytes, "b8 02 00 00 00")
        XCTAssertTrue(snapshot.instructions.first?.operands.contains("0x2") == true)
        XCTAssertEqual(snapshot.imageBytes, raw)
        XCTAssertEqual(snapshot.hexBytes, raw)
        let listing = DisassemblyListingBuilder.buildResolved(snapshot: snapshot)
        XCTAssertEqual(listing.resolved[base]?.isPatched, true)
        XCTAssertEqual(listing.resolved[base + 5]?.isPatched, false)
        XCTAssertEqual(snapshot.hexByteReader()(base, 6), Data([0xb8, 2, 0, 0, 0, 0xc3]))
    }

    func testShortARMEditDecodesWithTheOriginalThreeTrailingBytes() throws {
        let raw = Data([0x1f, 0x20, 0x03, 0xd5, 0xc0, 0x03, 0x5f, 0xd6])
        let snapshot = try analyze(raw, patches: [base: BytePatch(bytes: [0x3f])], arm64: true)
        XCTAssertEqual(snapshot.instructions.map(\.address), [base, base + 4])
        XCTAssertEqual(snapshot.instructions.first?.bytes, "3f 20 03 d5")
        XCTAssertEqual(snapshot.instructions.first?.mnemonic, "yield")
        XCTAssertEqual(snapshot.imageBytes, raw)
    }

    func testOneInstructionCanBecomeSeveralWithoutDroppingReplacementRows() throws {
        let raw = Data([0xb8, 1, 0, 0, 0, 0xc3])
        let snapshot = try analyze(raw, patches: [base: BytePatch(bytes: Array(repeating: 0x90, count: 5))])
        XCTAssertEqual(snapshot.instructions.map(\.address), (0..<6).map { base + UInt64($0) })
        XCTAssertEqual(snapshot.instructions.map(\.mnemonic), ["nop", "nop", "nop", "nop", "nop", "ret"])
        XCTAssertEqual(snapshot.instructions.map(\.bytes), ["90", "90", "90", "90", "90", "c3"])
    }

    func testWiderReplacementRemovesObsoleteInstructionBoundaries() throws {
        let raw = Data([0x90, 0x90, 0x90, 0x90, 0x90, 0xc3])
        let snapshot = try analyze(raw, patches: [base: BytePatch(bytes: [0xb8, 3, 0, 0, 0])])
        XCTAssertEqual(snapshot.instructions.map(\.address), [base, base + 5])
        XCTAssertEqual(snapshot.instructions.map(\.bytes), ["b8 03 00 00 00", "c3"])
    }

    func testInteriorBranchEditChangesTheProducedControlFlowTarget() throws {
        let snapshot = try analyze(Data([0xeb, 0, 0xc3, 0xc3]),
                                   patches: [base + 1: BytePatch(bytes: [1])])
        XCTAssertEqual(snapshot.controlFlowEdges.filter { $0.from == base && $0.kind == "branch" }.map(\.to),
                       [base + 3])
    }

    func testOverlapOrderIsIndependentOfDictionaryInsertionOrder() throws {
        let raw = Data([0xb8, 1, 0, 0, 0, 0xc3])
        var first: [UInt64: BytePatch] = [:]
        first[base] = BytePatch(bytes: Array(repeating: 0x90, count: 5))
        first[base + 2] = BytePatch(bytes: [0xc3])
        var second: [UInt64: BytePatch] = [:]
        second[base + 2] = first[base + 2]
        second[base] = first[base]
        let a = try analyze(raw, patches: first)
        let b = try analyze(raw, patches: second)
        XCTAssertEqual(a.instructions, b.instructions)
        XCTAssertEqual(a.hexByteReader()(base, 6), Data([0x90, 0x90, 0xc3, 0x90, 0x90, 0xc3]))
        XCTAssertEqual(a.hexByteReader()(base, 6), b.hexByteReader()(base, 6))
    }

    func testOverlayHandlesReadStartingInsideAPatchAndNonzeroDataIndex() throws {
        let overlay = try BytePatchOverlay(patches: [
            base: BytePatch(bytes: [1, 2, 3, 4, 5]),
            base + 3: BytePatch(bytes: [0x99]),
        ])
        let raw = Data([0xee, 0xee, 0x10, 0x11, 0x12, 0x13])[2...]
        let result = try XCTUnwrap(overlay.applying(to: raw, at: base + 2))
        XCTAssertEqual(Array(result), [3, 0x99, 5, 0x13])
        XCTAssertEqual(Array(raw), [0x10, 0x11, 0x12, 0x13])
    }

    func testAutomaticAndAuthoredTableReadsUseTheSamePatchedBytes() throws {
        let fixture = try tableFixture()
        let engine = AnalysisEngine(loader: EffectiveByteFixtureLoader(binary: fixture))
        var overrides = overrides([0x2008: BytePatch(bytes: [0x20])])
        overrides[0x1014] = AddressOverride(switchHint: SwitchHintOverride(
            tableBase: 0x2000, entryCount: 2, entryStride: 8, isRelativeToBase: false
        ))
        let snapshot = try engine.analyze(url: ignoredURL, overrides: overrides)
        XCTAssertEqual(snapshot.jumpTables[0x1014], [0x1018, 0x1020])
        XCTAssertEqual(snapshot.resolvedJumpTables(in: .primary)[0x1014], [0x1018, 0x1020])
        XCTAssertEqual(snapshot.imageBytes, fixture.bytes)
        XCTAssertEqual(snapshot.hexByteReader()(0x2008, 8), littleEndianWords([0x1020]))
    }

    func testProviderReloadReceivesPatchesAndRetainsEffectiveTableTargets() throws {
        let fixture = try tableFixture()
        let provider: any AnalysisProviding = AnalysisEngine(loader: EffectiveByteFixtureLoader(binary: fixture))
        let authored = overrides([0x2008: BytePatch(bytes: [0x20])])
        let fresh = try provider.analyze(url: ignoredURL, requestedSliceIndex: nil,
                                         overrides: authored, cancellation: .never)
        var persisted = try XCTUnwrap(fresh.analysis(in: .primary))
        persisted.jumpTables = [:]
        persisted.sections = []
        let restored = try provider.rehydrate(imageBytes: persisted.imageBytes, requestedSliceIndex: nil,
                                              preserving: persisted, overrides: authored, cancellation: .never)
        XCTAssertEqual(restored.jumpTables[0x1014], [0x1018, 0x1020])
        XCTAssertEqual(restored.instructions, persisted.instructions)
        XCTAssertEqual(restored.imageBytes, fixture.bytes)
    }

    func testAutomaticAndAuthoredTablesRejectBytesOwnedByANeighboringSection() throws {
        var fixture = try tableFixture()
        // The first declaration claims 16 bytes, but the second half belongs to
        // another section at a different VA. Section A may authorize only 8 bytes.
        fixture.sections.append(BinarySection(name: ".neighbor", address: 0x3000, size: 8,
                                               fileOffset: fixture.sections[1].fileOffset + 8,
                                               isExecutable: false, fileSize: 8))
        let hint = SwitchHintOverride(tableBase: 0x2000, entryCount: 2, entryStride: 8,
                                      isRelativeToBase: false)
        let snapshot = try AnalysisEngine(loader: EffectiveByteFixtureLoader(binary: fixture))
            .analyze(url: ignoredURL, overrides: [0x1014: AddressOverride(switchHint: hint)])
        XCTAssertNil(snapshot.jumpTables[0x1014])
        XCTAssertNil(snapshot.resolvedJumpTables(in: .primary)[0x1014])
        XCTAssertEqual(snapshot.hexByteReader()(0x2000, 8), littleEndianWords([0x1018]))
        XCTAssertNil(snapshot.hexByteReader()(0x2008, 8))
        XCTAssertEqual(snapshot.hexByteReader()(0x3000, 8), littleEndianWords([0x101c]))
    }

    func testRestoredRealImageWithoutSectionsNeverUsesTheLinearHeaderFallback() throws {
        var snapshot = try analyze(Data([0x90, 0xc3]), patches: [:])
        snapshot.sections = []
        XCTAssertFalse(snapshot.imageBytes.isEmpty)
        XCTAssertFalse(snapshot.hexBytes.isEmpty)
        XCTAssertNil(snapshot.hexByteReader()(base, 1))
        // A genuinely hand-built linear window without retained artifact bytes
        // keeps the preexisting fixture compatibility path.
        snapshot.imageBytes = Data()
        XCTAssertEqual(snapshot.hexByteReader()(base, 1), Data([0x90]))
    }

    func testMappingFailureRejectsTheWholeAnalysisInsteadOfUsingOldInstructions() throws {
        for patchAddress in [base + 6, base + 0x100] {
            XCTAssertThrowsError(try analyze(Data([0xb8, 1, 0, 0, 0, 0xc3]), patches: [
                patchAddress: BytePatch(bytes: [0x90]),
            ])) { error in
                XCTAssertEqual(error as? BytePatchOverlay.Failure, .unmappedPatch(address: patchAddress))
            }
        }
        XCTAssertThrowsError(try analyze(Data([0xb8, 1, 0, 0, 0, 0xc3]), patches: [
            base + 5: BytePatch(bytes: [0x90, 0x90]),
        ])) { error in
            XCTAssertEqual(error as? BytePatchOverlay.Failure, .unmappedPatch(address: self.base + 5))
        }
    }

    func testZeroFillAndPhysicalTailCannotAuthorizePatches() throws {
        for isZeroFill in [false, true] {
            var fixture = binary(Data([0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0xc3]))
            fixture.sections[0].fileSize = 4
            fixture.sections[0].isZeroFill = isZeroFill
            fixture.executableTextSection = fixture.sections[0]
            let address = isZeroFill ? base : base + 6
            let engine = AnalysisEngine(loader: EffectiveByteFixtureLoader(binary: fixture))
            XCTAssertThrowsError(try engine.analyze(url: ignoredURL, overrides: overrides([
                address: BytePatch(bytes: [0x90]),
            ]))) { error in
                XCTAssertEqual(error as? BytePatchOverlay.Failure, .unmappedPatch(address: address))
            }
        }
    }

    func testMalformedPatchSpansFailDeterministically() throws {
        XCTAssertThrowsError(try BytePatchOverlay(patches: [UInt64.max: BytePatch(bytes: [0])])) {
            XCTAssertEqual($0 as? BytePatchOverlay.Failure, .addressOverflow(address: UInt64.max))
        }
        XCTAssertThrowsError(try BytePatchOverlay(patches: [base: BytePatch(
            bytes: Array(repeating: 0, count: BytePatch.maxByteCount + 1)
        )])) {
            XCTAssertEqual($0 as? BytePatchOverlay.Failure,
                           .oversizedPatch(address: self.base, count: BytePatch.maxByteCount + 1))
        }
        XCTAssertTrue(try BytePatchOverlay(patches: [UInt64.max: BytePatch(bytes: [])]).edits.isEmpty)
    }

    func testWholeReadRejectsInteriorAliasesAndMappingGaps() {
        let ordinary = FileAddressMapping(fileOffset: 0, size: 128, virtualAddress: base)
        for alias in [
            FileAddressMapping(fileOffset: 40, size: 8, virtualAddress: 0x3000),
            FileAddressMapping(fileOffset: 200, size: 8, virtualAddress: base + 40),
        ] {
            XCTAssertNil(FileAddressMapping.resolvedFileRange(
                forVirtualAddress: base + 32, count: 32, in: [ordinary, alias]
            ))
        }
        XCTAssertNil(FileAddressMapping.resolvedFileRange(forVirtualAddress: base + 2, count: 8, in: [
            .init(fileOffset: 0, size: 4, virtualAddress: base),
            .init(fileOffset: 8, size: 4, virtualAddress: base + 8),
        ]))
        XCTAssertEqual(FileAddressMapping.resolvedFileRange(forVirtualAddress: base + 32, count: 32,
                                                           in: [ordinary]), 32..<64)
    }

    func testSelectedSliceBoundsAndOriginalArtifactBytesRemainAuthoritative() throws {
        let raw = Data([0xb8, 1, 0, 0, 0, 0xc3])
        var fixture = binary(raw)
        fixture.bytes = Data([0xaa, 0xbb, 0xcc]) + raw + Data([0xdd, 0xee])
        fixture.sliceOffset = 3
        fixture.sliceSize = UInt64(raw.count)
        let snapshot = try AnalysisEngine(loader: EffectiveByteFixtureLoader(binary: fixture))
            .analyze(url: ignoredURL, overrides: overrides([base + 1: BytePatch(bytes: [4])]))
        XCTAssertEqual(snapshot.imageBytes, raw)
        XCTAssertEqual(snapshot.instructions.first?.bytes, "b8 04 00 00 00")
        XCTAssertNil(snapshot.hexByteReader()(base + 5, 2), "trailing container bytes are not in this slice")
    }

    func testPatchedBinaryExportMatchesTheEffectiveDecodedBytes() throws {
        let fixture = MachOFixture.makeExecutable(code: Data([0xb8, 1, 0, 0, 0, 0xc3]),
                                                  cpuType: MachOConstants.cpuTypeX86_64)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("effective-export-\(UUID().uuidString)")
        try fixture.bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let patches: [UInt64: BytePatch] = [
            fixture.baseAddress: BytePatch(bytes: Array(repeating: 0x90, count: 5)),
            fixture.baseAddress + 2: BytePatch(bytes: [0xc3]),
        ]
        let snapshot = try AnalysisEngine().analyze(url: url, overrides: overrides(patches))
        let exported = try MachOPatchWriter().makePatchedData(originalData: fixture.bytes, patches: patches)
        let decoded = snapshot.instructions.flatMap { BytePatch.parse(hex: $0.bytes)?.bytes ?? [] }
        XCTAssertEqual(decoded, Array(exported[fixture.codeOffset...]))
        XCTAssertEqual(snapshot.imageBytes, fixture.bytes)
        XCTAssertEqual(Array(exported[..<fixture.codeOffset]), Array(fixture.bytes[..<fixture.codeOffset]))
    }

    func testPatchedBinaryExportRejectsDisagreeingSectionAndSegmentOffsets() throws {
        let fixture = MachOFixture.makeExecutable(code: Data([0xb8, 1, 0, 0, 0, 0xc3]),
                                                  cpuType: MachOConstants.cpuTypeX86_64)
        var original = fixture.bytes
        // The fixture has a 32-byte header, a 72-byte segment command prefix,
        // and section_64.offset 48 bytes into its section. Move only that field:
        // the segment maps the patch VA to codeOffset; the section maps it +1.
        let fieldOffset = 32 + 72 + 48
        let movedOffset = UInt32(fixture.codeOffset + 1)
        original.replaceSubrange(fieldOffset..<(fieldOffset + 4), with:
            (0..<4).map { UInt8(truncatingIfNeeded: movedOffset >> ($0 * 8)) })
        let parsed = try MachOParser().parse(original)
        XCTAssertEqual(parsed.executableTextSection?.fileOffset, movedOffset)
        XCTAssertThrowsError(try MachOPatchWriter().makePatchedData(
            originalData: original, patches: [fixture.baseAddress: BytePatch(bytes: [0x90])]
        )) { error in
            XCTAssertEqual(error as? MachOPatchWriter.PatchWriteError,
                           .inconsistentMapping(address: fixture.baseAddress))
        }
        XCTAssertEqual(original[fixture.codeOffset], 0xb8)
    }

    @MainActor
    func testNOPFillsFocusedInstructionWidthAndHexUsesTheSameOverlapOrder() throws {
        let raw = Data([0xb8, 1, 0, 0, 0, 0xc3])
        let fixture = binary(raw)
        let engine = AnalysisEngine(loader: EffectiveByteFixtureLoader(binary: fixture))
        var snapshot = try engine.analyze(url: ignoredURL)
        let slot = ImageSlot(rawValue: 1)
        let primary = try XCTUnwrap(snapshot.binaries.first)
        let sibling = BinaryImage(id: UUID(), name: "sibling", path: primary.path,
                                  kind: primary.kind, architecture: primary.architecture, slot: slot)
        snapshot.binaries.append(sibling)
        snapshot.replaceAnalysis(try XCTUnwrap(snapshot.analysis(in: .primary)), in: slot)
        let store = WorkspaceStore(workspaceName: "effective NOP", snapshot: snapshot, engine: engine,
                                   autosaveScheduler: nil)
        store.focusImage(slot)
        store.withSynchronousReanalysis { store.patchNOP(base) }
        XCTAssertEqual(store.snapshot.patches(in: slot)[base]?.bytes, Array(repeating: 0x90, count: 5))
        XCTAssertTrue(store.snapshot.patches(in: .primary).isEmpty)
        XCTAssertEqual(store.snapshot.analysis(in: slot)?.instructions.count, 6)
        store.withSynchronousReanalysis { store.patchByte(at: base + 2, value: 0xc3) }
        XCTAssertEqual(store.patchedHexWindow().bytes, Data([0x90, 0x90, 0xc3, 0x90, 0x90, 0xc3]))
        XCTAssertEqual(store.snapshot.hexByteReader(in: slot)(base, 6), store.patchedHexWindow().bytes)
        XCTAssertEqual(store.snapshot.hexByteReader(in: .primary)(base, 6), raw)
    }

    @MainActor
    func testNOPRejectsAnEarlierInteriorEditThatWouldOverrideItsReplacement() throws {
        let fixture = binary(Data([0xb8, 1, 0, 0, 0, 0xc3]))
        let engine = AnalysisEngine(loader: EffectiveByteFixtureLoader(binary: fixture))
        let snapshot = try engine.analyze(url: ignoredURL)
        let store = WorkspaceStore(workspaceName: "NOP overlap", snapshot: snapshot,
                                   engine: engine, autosaveScheduler: nil)
        store.withSynchronousReanalysis { store.patchByte(at: base + 1, value: 2) }
        let before = store.snapshot.patches(in: .primary)
        XCTAssertFalse(store.withSynchronousReanalysis { store.patchNOP(base) })
        XCTAssertEqual(store.snapshot.patches(in: .primary), before)
        XCTAssertTrue(store.lastIssue?.contains("overlapping interior byte patches") == true)
        XCTAssertThrowsError(try WorkspaceScriptingAPI(store: store).execute(
            "patch-bytes", arguments: .object(["address": .hex(base), "nop": .bool(true)])
        ))
        XCTAssertEqual(store.snapshot.patches(in: .primary), before)
        store.withSynchronousReanalysis { store.clearPatch(base + 1) }
        XCTAssertTrue(store.withSynchronousReanalysis { store.patchNOP(base) })
        XCTAssertEqual(store.patchedHexWindow().bytes, Data([0x90, 0x90, 0x90, 0x90, 0x90, 0xc3]))
    }

    @MainActor
    func testScriptingReportsTheActualX86NOPAndThrowsForRejectedEdits() throws {
        let fixture = binary(Data([0xb8, 1, 0, 0, 0, 0xc3]))
        let engine = AnalysisEngine(loader: EffectiveByteFixtureLoader(binary: fixture))
        let store = WorkspaceStore(workspaceName: "scripted bytes",
                                   snapshot: try engine.analyze(url: ignoredURL),
                                   engine: engine, autosaveScheduler: nil)
        let api = WorkspaceScriptingAPI(store: store)
        let nop = try api.execute("patch-bytes", arguments: .object([
            "address": .hex(base), "nop": .bool(true),
        ]))
        XCTAssertEqual(nop["bytes"]?.stringValue, "90 90 90 90 90")
        XCTAssertEqual(store.snapshot.instructions.count, 6)
        let failedAnalysis = try api.execute("patch-bytes", arguments: .object([
            "address": .hex(base + 5), "bytes": .string("90 90"),
        ]))
        XCTAssertEqual(failedAnalysis["committed"], .bool(true))
        XCTAssertEqual(failedAnalysis["reanalysisStatus"], .string("failed"))
        XCTAssertTrue(failedAnalysis["reanalysisDiagnostic"]?.stringValue?.contains("unambiguous file-backed mapping") == true)
        XCTAssertTrue(store.lastIssue?.contains("unambiguous file-backed mapping") == true)
        XCTAssertNotNil(store.snapshot.patches(in: .primary)[base + 5], "failed mapped edits remain undoable")
        let retry = try api.execute("patch-bytes", arguments: .object([
            "address": .hex(base + 5), "bytes": .string("90 90"),
        ]))
        XCTAssertEqual(retry["committed"], .bool(true))
        XCTAssertEqual(retry["reanalysisStatus"], .string("failed"), "retry must revalidate the retained edit")
        _ = try api.execute("clear-patch", arguments: .object(["address": .hex(base + 5)]))
        XCTAssertThrowsError(try api.execute("patch-bytes", arguments: .object([
            "address": .hex(UInt64.max), "bytes": .string("90"),
        ])))
        XCTAssertNil(store.snapshot.patches(in: .primary)[UInt64.max], "overflow is rejected before mutation")
    }

    @MainActor
    func testHexEditPropagatesSpanValidationFailureWithoutMutating() {
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "top", path: "", kind: "fixture", architecture: "x86_64")],
            functions: [],
            instructions: [InstructionRow(address: UInt64.max, bytes: "90", mnemonic: "nop", operands: "",
                                          hasBreakpoint: false, comment: nil)],
            xrefs: [], hexBytes: Data([0x90]),
            sections: [SectionSummary(id: UUID(), name: ".text", address: UInt64.max, size: 1,
                                      fileOffset: 0, isExecutable: true)],
            imageBytes: Data([0x90])
        )
        let store = WorkspaceStore(workspaceName: "top address", snapshot: snapshot,
                                   engine: AnalysisEngine(), autosaveScheduler: nil)
        XCTAssertFalse(store.applyHexByteEdit(offset: 0, value: 0xcc))
        XCTAssertTrue(store.lastIssue?.contains("beyond the address space") == true)
        XCTAssertFalse(store.applyHexEdit(offset: 0, hexByte: "cc"))
        XCTAssertTrue(store.snapshot.patches(in: .primary).isEmpty)
    }

    @MainActor
    func testInvalidMappedEditSurfacesReanalysisFailureAndStaysUndoable() throws {
        let fixture = binary(Data([0x90, 0xc3]))
        let engine = AnalysisEngine(loader: EffectiveByteFixtureLoader(binary: fixture))
        let snapshot = try engine.analyze(url: ignoredURL)
        let store = WorkspaceStore(workspaceName: "invalid edit", snapshot: snapshot,
                                   engine: engine, autosaveScheduler: nil)
        store.withSynchronousReanalysis { store.setPatch(base + 1, BytePatch(bytes: [0x90, 0x90])) }
        XCTAssertTrue(store.lastIssue?.contains("unambiguous file-backed mapping") == true)
        XCTAssertEqual(store.snapshot.instructions, snapshot.instructions)
        XCTAssertNotNil(store.snapshot.patches(in: .primary)[base + 1], "the failed edit can still be corrected or cleared")
        XCTAssertEqual(store.patchedHexWindow().bytes, fixture.bytes, "an invalid span must not paint its in-range prefix")
        XCTAssertTrue(store.patchedHexWindow().patchedOffsets.isEmpty)
        XCTAssertNil(store.snapshot.hexByteReader()(base, 1), "readers do not quietly omit an invalid authored edit")
        store.withSynchronousReanalysis { store.clearPatch(base + 1) }
        XCTAssertTrue(store.snapshot.patches(in: .primary).isEmpty)
        XCTAssertNil(store.lastIssue)
    }

    private func overrides(_ patches: [UInt64: BytePatch]) -> [UInt64: AddressOverride] {
        patches.mapValues { AddressOverride(patch: $0) }
    }

    private func analyze(_ data: Data, patches: [UInt64: BytePatch], arm64: Bool = false) throws -> WorkspaceSnapshot {
        try AnalysisEngine(loader: EffectiveByteFixtureLoader(binary: binary(data, arm64: arm64)))
            .analyze(url: ignoredURL, overrides: overrides(patches))
    }

    private func binary(_ data: Data, arm64: Bool = false) -> LoadedBinary {
        let text = BinarySection(name: ".text", address: base, size: UInt64(data.count), fileOffset: 0,
                                 isExecutable: true, fileSize: UInt64(data.count))
        return LoadedBinary(name: "effective-byte-fixture", path: ignoredURL.path, isBundle: false,
                            cpuType: arm64 ? MachOConstants.cpuTypeARM64 : MachOConstants.cpuTypeX86_64,
                            fileTypeName: "fixture", architectureDisplayName: arm64 ? "arm64" : "x86_64",
                            metadata: .empty, bytes: data, sliceOffset: 0, sliceSize: UInt64(data.count),
                            sections: [text], executableTextSection: text, entryPointAddress: base,
                            symbols: [], imports: [], indirectSymbols: [], exports: [], stringLiterals: [],
                            functionStarts: [base], objcSelectors: [:])
    }

    private func tableFixture() throws -> LoadedBinary {
        let source = ["cmp x0, #1", "b.hi 0x1020", "adrp x8, 0x2000", "add x8, x8, #0",
                      "ldr x9, [x8, x0, lsl #3]", "br x9", "ret", "ret", "ret"]
        var code = Data()
        for (index, instruction) in source.enumerated() {
            // The in-app assembler has no `adrp` family; encode that one form directly.
            if instruction == "adrp x8, 0x2000" {
                let pc = base + UInt64(index * 4)
                let pages = Int64(0x2000 >> 12) - Int64(pc >> 12)
                let word = UInt32(0x9000_0000) | (UInt32(pages & 0x3) << 29)
                    | (UInt32((pages >> 2) & 0x7_FFFF) << 5) | 8
                code.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) })
                continue
            }
            switch ARM64Assembler().assemble(instruction, at: base + UInt64(index * 4)) {
            case let .success(bytes): code.append(contentsOf: bytes)
            case let .failure(error):
                XCTFail("Fixture assembly failed: \(instruction): \(error)")
                throw FixtureFailure.assembly
            }
        }
        var fixture = binary(code, arm64: true)
        fixture.sections.append(BinarySection(name: ".const", address: 0x2000, size: 16,
                                               fileOffset: UInt64(code.count), isExecutable: false, fileSize: 16))
        fixture.bytes.append(littleEndianWords([0x1018, 0x101c]))
        fixture.sliceSize = UInt64(fixture.bytes.count)
        return fixture
    }

    private func littleEndianWords(_ values: [UInt64]) -> Data {
        Data(values.flatMap { value in (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } })
    }

    private enum FixtureFailure: Error { case assembly }
}

private struct EffectiveByteFixtureLoader: BinaryLoader {
    let binary: LoadedBinary
    func load(at url: URL) throws -> LoadedBinary { binary }
}
