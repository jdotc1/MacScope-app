import XCTest
@testable import MacScope

/// WS-4 acceptance oracle: image-aware addressing. Two images can legitimately contain the SAME
/// virtual address (every arm64 executable prefers 0x1_0000_0000), so all workspace-level user
/// state is keyed by `ImageAddress { slot, address }`, not a bare `UInt64`. These tests exercise
/// the collision case DELIBERATELY — an override/bookmark/patch authored in one image must never
/// bind to another image at the same VA — plus the v25 persistence migration (additive column +
/// widened UNIQUE index without index resurrection) and the single-image byte-identity contract.
final class WorkspaceImageIdentityTests: XCTestCase {
    private let collidingAddress: UInt64 = 0x1_0000_0004

    // MARK: - Model-level collision isolation

    /// Two overrides at the SAME address in different slots are independent entries — the whole
    /// reason the key is `ImageAddress` and not `UInt64`. A bare-address map would have collapsed
    /// these to one (last-write-wins), silently losing image A's rename.
    func testOverridesAtCollidingAddressStayPerImage() {
        var snapshot = WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data())
        snapshot.addressOverrides = [
            ImageAddress(slot: .primary, address: collidingAddress): AddressOverride(customName: "imageA_entry"),
            ImageAddress(slot: ImageSlot(rawValue: 1), address: collidingAddress): AddressOverride(customName: "imageB_entry"),
        ]
        XCTAssertEqual(snapshot.addressOverrides.count, 2, "same VA in two slots must be two entries")
        XCTAssertEqual(snapshot.addressOverrides[.primary(collidingAddress)]?.customName, "imageA_entry")
        XCTAssertEqual(snapshot.addressOverrides[ImageAddress(slot: ImageSlot(rawValue: 1), address: collidingAddress)]?.customName,
                       "imageB_entry")
    }

    /// The primary render helpers resolve only the PRIMARY image's overrides; a sibling image's
    /// override at the same VA must be invisible to primary-image rendering.
    func testPrimaryHelpersIgnoreSiblingImageOverrides() {
        var snapshot = WorkspaceSnapshot(binaries: [image(slot: .primary)], functions: [], instructions: [], xrefs: [], hexBytes: Data())
        snapshot.addressOverrides = [
            .primary(collidingAddress): AddressOverride(customName: "primaryName"),
            ImageAddress(slot: ImageSlot(rawValue: 1), address: collidingAddress): AddressOverride(customName: "siblingName", patch: BytePatch(bytes: [0x90])),
        ]
        XCTAssertEqual(snapshot.displayName(at: collidingAddress, default: "raw"), "primaryName")
        // The patch lives in the sibling slot only, so the primary image's patch set excludes it.
        XCTAssertTrue(snapshot.patches(in: .primary).isEmpty,
                      "a sibling image's patch must not appear in the primary image's patch set")
        XCTAssertEqual(snapshot.patches(in: ImageSlot(rawValue: 1))[collidingAddress]?.bytes, [0x90])
    }

    /// `save-patched-binary` writes ONE image's patches to ONE file. With patches authored in two
    /// images at the same VA, the primary file must receive only the primary image's patch —
    /// otherwise image B's patch corrupts image A's binary at the aliased offset.
    func testPatchSetIsSlotFilteredForPatchWriting() {
        var snapshot = WorkspaceSnapshot(binaries: [image(slot: .primary), image(slot: ImageSlot(rawValue: 1))], functions: [], instructions: [], xrefs: [], hexBytes: Data())
        snapshot.addressOverrides = [
            .primary(collidingAddress): AddressOverride(patch: BytePatch(bytes: [0xAA])),
            ImageAddress(slot: ImageSlot(rawValue: 1), address: collidingAddress): AddressOverride(patch: BytePatch(bytes: [0xBB])),
        ]
        XCTAssertEqual(snapshot.patches(in: .primary), [collidingAddress: BytePatch(bytes: [0xAA])])
        XCTAssertEqual(snapshot.patches(in: ImageSlot(rawValue: 1)), [collidingAddress: BytePatch(bytes: [0xBB])])
    }

    // MARK: - Store: atomic slot remap

    /// A package-import collision renumbers an image's slot. Every keyed collection must move in
    /// ONE mutation — a partial remap orphans authoring. remapImageSlot(from:to:) is that primitive.
    @MainActor
    func testRemapImageSlotRewritesEveryKeyedCollectionAtomically() {
        let old = ImageSlot(rawValue: 1)
        let new = ImageSlot(rawValue: 7)
        var snapshot = WorkspaceSnapshot(binaries: [image(slot: .primary), image(slot: old)], functions: [], instructions: [], xrefs: [], hexBytes: Data())
        snapshot.addressOverrides = [
            .primary(0x1000): AddressOverride(customName: "keepPrimary"),
            ImageAddress(slot: old, address: 0x2000): AddressOverride(customName: "moveMe"),
        ]
        snapshot.bookmarks = [Bookmark(address: 0x2000, imageSlot: old, name: "bm")]
        snapshot.manualXRefs = [ManualXRef(from: 0x2000, to: 0x3000, kind: "call", isSuppression: false, imageSlot: old)]
        snapshot.segmentOverrides = [SegmentOverride(originalName: "__TEXT,__text", imageSlot: old, displayName: "renamed")]

        let store = WorkspaceStore(workspaceName: "Remap", snapshot: snapshot, engine: AnalysisEngine())
        store.remapImageSlot(from: old, to: new)
        let result = store.snapshot

        // Primary stays put.
        XCTAssertEqual(result.addressOverrides[.primary(0x1000)]?.customName, "keepPrimary")
        // Everything in `old` moved to `new`, nothing stranded.
        XCTAssertNil(result.addressOverrides[ImageAddress(slot: old, address: 0x2000)])
        XCTAssertEqual(result.addressOverrides[ImageAddress(slot: new, address: 0x2000)]?.customName, "moveMe")
        XCTAssertEqual(result.bookmarks.first?.imageSlot, new)
        XCTAssertEqual(result.manualXRefs.first?.imageSlot, new)
        XCTAssertEqual(result.segmentOverrides.first?.imageSlot, new)
        XCTAssertEqual(result.binaries.first(where: { $0.name == "img\(old.rawValue)" })?.slot, new)
    }

    // MARK: - Store: collision-safe focused authoring

    /// The Phase-2 focus seam is `snapshot.primarySlot`, so placing slot 1 first represents the
    /// image being viewed/authored without introducing Phase-4 switchable focus. Pre-existing
    /// slot-0 records at identical keys must neither block nor be rewritten by slot-1 edits.
    @MainActor
    func testFocusedSiblingAuthoringUsesSlotQualifiedCollisionKeys() {
        let slotA = ImageSlot.primary
        let slotB = ImageSlot(rawValue: 1)
        let address: UInt64 = 0x1_0000_0000
        let target = address + 4
        let sectionName = "__TEXT,__text"

        func analysis(named name: String) -> ImageAnalysis {
            var analysis = ImageAnalysis()
            analysis.functions = [FunctionSummary(
                id: UUID(), name: name, startAddress: address, endAddress: target, confidence: 1
            )]
            analysis.instructions = [InstructionRow(
                address: address, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "",
                hasBreakpoint: false, comment: name
            )]
            analysis.sections = [SectionSummary(
                id: UUID(), name: sectionName, address: address, size: 4,
                fileOffset: 0, isExecutable: true
            )]
            return analysis
        }

        var snapshot = WorkspaceSnapshot(
            binaries: [image(slot: slotB), image(slot: slotA)],
            analysisBySlot: [slotA: analysis(named: "image_a"), slotB: analysis(named: "image_b")]
        )
        snapshot.bookmarks = [Bookmark(address: address, imageSlot: slotA, name: "A bookmark")]
        snapshot.manualXRefs = [ManualXRef(
            from: address, to: target, kind: XRefKind.call, isSuppression: false, imageSlot: slotA
        )]
        snapshot.segmentOverrides = [SegmentOverride(
            originalName: sectionName, imageSlot: slotA, displayName: "A text"
        )]

        let store = WorkspaceStore(
            workspaceName: "Collision Authoring", snapshot: snapshot,
            engine: AnalysisEngine(), autosaveScheduler: nil
        )
        // Phase 4: focus is now a real switchable store property (no longer inferred from binary
        // order). Explicitly focus the sibling so bare-address authoring binds to slot B.
        store.focusImage(slotB)
        XCTAssertEqual(store.focusedImageSlot, slotB)
        // Focus change resets bare-address selection (safety); simulate the user selecting the
        // colliding address within image B, which is what a real removeBookmark enablement needs.
        store.selectedAddress = address

        // A bookmark at the colliding address in A does not authorize navigation while B is focused.
        XCTAssertFalse(store.isEnabled(.removeBookmark))
        store.navigateToBookmark(at: address)
        XCTAssertEqual(store.lastIssue, "No bookmark at that address.")

        store.addBookmark(at: address, name: "B bookmark")
        XCTAssertTrue(store.isEnabled(.removeBookmark))
        store.addManualXRef(from: address, to: target, kind: XRefKind.call)
        store.renameSegment(sectionName: sectionName, displayName: "B text")

        XCTAssertEqual(store.snapshot.bookmarks.first(where: {
            $0.imageSlot == slotA && $0.address == address
        })?.name, "A bookmark")
        XCTAssertEqual(store.snapshot.bookmarks.first(where: {
            $0.imageSlot == slotB && $0.address == address
        })?.name, "B bookmark")
        XCTAssertTrue(store.snapshot.manualXRefs.contains {
            $0.imageSlot == slotA && !$0.isSuppression && $0.endpointKey == XRefEndpointKey(
                from: address, to: target, kind: XRefKind.call
            )
        })
        XCTAssertTrue(store.snapshot.manualXRefs.contains {
            $0.imageSlot == slotB && !$0.isSuppression && $0.endpointKey == XRefEndpointKey(
                from: address, to: target, kind: XRefKind.call
            )
        })
        XCTAssertEqual(store.snapshot.segmentOverrides.first(where: {
            $0.imageSlot == slotA && $0.originalName == sectionName
        })?.displayName, "A text")
        XCTAssertEqual(store.snapshot.segmentOverrides.first(where: {
            $0.imageSlot == slotB && $0.originalName == sectionName
        })?.displayName, "B text")

        // Flipping B's xref to a suppression must remove only B's add; A's add remains intact.
        store.suppressXRef(from: address, to: target, kind: XRefKind.call)
        XCTAssertTrue(store.snapshot.manualXRefs.contains {
            $0.imageSlot == slotA && !$0.isSuppression && $0.endpointKey == XRefEndpointKey(
                from: address, to: target, kind: XRefKind.call
            )
        })
        XCTAssertFalse(store.snapshot.manualXRefs.contains {
            $0.imageSlot == slotB && !$0.isSuppression && $0.endpointKey == XRefEndpointKey(
                from: address, to: target, kind: XRefKind.call
            )
        })
        XCTAssertTrue(store.snapshot.manualXRefs.contains {
            $0.imageSlot == slotB && $0.isSuppression && $0.endpointKey == XRefEndpointKey(
                from: address, to: target, kind: XRefKind.call
            )
        })

        // Removing/clearing B's records must leave the colliding A records untouched.
        store.removeBookmark(at: address)
        store.clearSegmentOverride(sectionName: sectionName)
        XCTAssertTrue(store.snapshot.bookmarks.contains {
            $0.imageSlot == slotA && $0.address == address && $0.name == "A bookmark"
        })
        XCTAssertFalse(store.snapshot.bookmarks.contains {
            $0.imageSlot == slotB && $0.address == address
        })
        XCTAssertTrue(store.snapshot.segmentOverrides.contains {
            $0.imageSlot == slotA && $0.originalName == sectionName && $0.displayName == "A text"
        })
        XCTAssertFalse(store.snapshot.segmentOverrides.contains {
            $0.imageSlot == slotB && $0.originalName == sectionName
        })
    }

    // MARK: - Store: slot-targeted dSYM injection

    /// A workspace's first image is its primary image even when durable slot remapping means that
    /// image is no longer literal slot 0. The convenience injection entry point must resolve that
    /// identity dynamically and must not synthesize an orphan analysis bucket in slot 0.
    @MainActor
    func testDefaultDSYMInjectionUsesNonzeroPrimarySlot() {
        let slot = ImageSlot(rawValue: 7)
        let address: UInt64 = 0x1_0000_0000
        let importedLines = [SourceLineEntry(
            address: address, file: "Nonzero.c", line: 7, column: 1, endSequence: false
        )]

        var targetAnalysis = ImageAnalysis()
        targetAnalysis.functions = [FunctionSummary(
            id: UUID(), name: "before", startAddress: address,
            endAddress: address + 4, confidence: 1
        )]
        targetAnalysis.sections = [SectionSummary(
            id: UUID(), name: "__TEXT,__text", address: address, size: 4,
            fileOffset: 0, isExecutable: true
        )]
        let snapshot = WorkspaceSnapshot(
            binaries: [image(slot: slot)], analysisBySlot: [slot: targetAnalysis]
        )
        let store = WorkspaceStore(
            workspaceName: "Nonzero Primary dSYM", snapshot: snapshot,
            engine: AnalysisEngine(), autosaveScheduler: nil
        )
        XCTAssertEqual(store.snapshot.primarySlot, slot)

        let result = DSYMImportResult(
            functions: [DWARFFunctionSymbol(address: address, name: "recovered_name")],
            sourceLines: importedLines,
            matchedUUID: "77777777-7777-7777-7777-777777777777",
            dwarfURL: URL(fileURLWithPath: "/tmp/nonzero-primary.dSYM")
        )

        XCTAssertEqual(store.injectDebugSymbols(result), 1)
        XCTAssertEqual(store.snapshot.analysis(in: slot)?.sourceLines, importedLines)
        XCTAssertEqual(store.snapshot.addressOverrides[
            ImageAddress(slot: slot, address: address)
        ]?.customName, "recovered_name")
        XCTAssertNil(store.snapshot.analysis(in: .primary),
                     "default injection must not create an orphan literal-slot-0 analysis")
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)])
    }

    /// A dSYM result already matched to sibling B must validate and write through B's analysis
    /// bucket. Primary A deliberately shares one VA but not B's second function, and has a real
    /// source path so an accidental primary re-analysis is observable after awaiting completion.
    @MainActor
    func testSiblingDSYMInjectionTargetsMatchedSlotAndPreservesPrimaryAtCollision() async throws {
        let (primaryURL, _) = try primaryFixtureURL()
        defer { try? FileManager.default.removeItem(at: primaryURL) }

        let slotA = ImageSlot.primary
        let slotB = ImageSlot(rawValue: 1)
        let collidingVA: UInt64 = 0x1_0000_0000
        let siblingOnlyVA = collidingVA + 0x100
        let uuidA = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let uuidB = "11111111-2222-3333-4444-555555555555"

        var binaryA = image(slot: slotA)
        binaryA.path = primaryURL.path
        binaryA.metadata.uuid = uuidA
        var binaryB = image(slot: slotB)
        binaryB.path = ""
        binaryB.metadata.uuid = uuidB

        var analysisA = ImageAnalysis()
        analysisA.functions = [FunctionSummary(
            id: UUID(), name: "a_collision", startAddress: collidingVA,
            endAddress: collidingVA + 4, confidence: 1
        )]
        analysisA.instructions = [InstructionRow(
            address: collidingVA, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "",
            hasBreakpoint: true, comment: "primary must stay exact"
        )]
        analysisA.sections = [SectionSummary(
            id: UUID(), name: "__TEXT,__text", address: collidingVA, size: 4,
            fileOffset: 0, isExecutable: true
        )]
        analysisA.sourceLines = [SourceLineEntry(
            address: collidingVA, file: "A.c", line: 10, column: 1, endSequence: false
        )]
        analysisA.hexBytes = Data([0xA0, 0xA1])
        analysisA.imageBytes = Data([0xA2, 0xA3])

        var analysisB = ImageAnalysis()
        analysisB.functions = [
            FunctionSummary(id: UUID(), name: "b_collision", startAddress: collidingVA,
                            endAddress: collidingVA + 4, confidence: 1),
            FunctionSummary(id: UUID(), name: "b_only", startAddress: siblingOnlyVA,
                            endAddress: siblingOnlyVA + 4, confidence: 1),
        ]
        analysisB.instructions = [
            InstructionRow(address: collidingVA, bytes: "00 00 80 d2", mnemonic: "mov",
                           operands: "x0, #0", hasBreakpoint: false, comment: "sibling"),
            InstructionRow(address: siblingOnlyVA, bytes: "c0 03 5f d6", mnemonic: "ret",
                           operands: "", hasBreakpoint: false, comment: "sibling-only"),
        ]
        analysisB.sections = [SectionSummary(
            id: UUID(), name: "__TEXT,__text", address: collidingVA, size: 0x200,
            fileOffset: 0, isExecutable: true
        )]
        analysisB.sourceLines = [SourceLineEntry(
            address: collidingVA, file: "old-B.c", line: 1, column: 1, endSequence: false
        )]
        analysisB.imageBytes = Data([0xB0, 0xB1, 0xB2, 0xB3])
        analysisB.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(
            binary: binaryB,
            analysis: analysisB
        )
        let siblingFingerprintBefore = try XCTUnwrap(analysisB.analysisInputFingerprint)

        let snapshot = WorkspaceSnapshot(
            binaries: [binaryA, binaryB], analysisBySlot: [slotA: analysisA, slotB: analysisB]
        )
        let store = WorkspaceStore(
            workspaceName: "Sibling dSYM", snapshot: snapshot,
            engine: AnalysisEngine(), autosaveScheduler: nil
        )
        let primaryBefore = try XCTUnwrap(store.snapshot.analysis(in: slotA))
        let primaryBinaryBefore = try XCTUnwrap(store.snapshot.binary(in: slotA))
        let siblingBinaryBefore = try XCTUnwrap(store.snapshot.binary(in: slotB))

        let importedLines = [
            SourceLineEntry(address: collidingVA, file: "B.c", line: 20,
                            column: 1, endSequence: false),
            SourceLineEntry(address: siblingOnlyVA, file: "B.c", line: 30,
                            column: 1, endSequence: false),
        ]
        let result = DSYMImportResult(
            functions: [
                DWARFFunctionSymbol(address: collidingVA, name: "b_collision_dsym"),
                DWARFFunctionSymbol(address: siblingOnlyVA, name: "b_only_dsym"),
            ],
            sourceLines: importedLines,
            types: [DWARFType(
                name: "SiblingRecord", kind: "struct", byteSize: 4,
                members: [DWARFTypeMember(name: "value", typeName: "int", byteOffset: 0)]
            )],
            matchedUUID: uuidB,
            dwarfURL: URL(fileURLWithPath: "/tmp/B.dSYM/Contents/Resources/DWARF/B")
        )
        XCTAssertEqual(result.matchedUUID, binaryB.metadata.uuid)

        XCTAssertEqual(store.injectDebugSymbols(result, into: slotB), 2)
        await store.awaitPendingReanalysis()

        XCTAssertEqual(store.snapshot.analysis(in: slotB)?.sourceLines, importedLines)
        let siblingAfter = try XCTUnwrap(store.snapshot.analysis(in: slotB))
        XCTAssertNotEqual(siblingAfter.analysisInputFingerprint, siblingFingerprintBefore)
        XCTAssertEqual(
            siblingAfter.analysisInputFingerprint,
            try AnalysisFingerprintBuilder.fingerprint(binary: siblingBinaryBefore, analysis: siblingAfter)
        )
        XCTAssertEqual(store.snapshot.binary(in: slotB), siblingBinaryBefore)
        XCTAssertEqual(store.snapshot.addressOverrides[
            ImageAddress(slot: slotB, address: collidingVA)
        ]?.customName, "b_collision_dsym")
        XCTAssertEqual(store.snapshot.addressOverrides[
            ImageAddress(slot: slotB, address: siblingOnlyVA)
        ]?.customName, "b_only_dsym")
        XCTAssertNil(store.snapshot.addressOverrides[.primary(collidingVA)])
        XCTAssertNil(store.snapshot.addressOverrides[.primary(siblingOnlyVA)])
        XCTAssertTrue(store.snapshot.typeDefinitions.contains { $0.name == "SiblingRecord" })

        // B's colliding debug data and authoring must not rewrite or re-analyze A.
        let primaryAfter = try XCTUnwrap(store.snapshot.analysis(in: slotA))
        XCTAssertEqual(store.snapshot.binary(in: slotA), primaryBinaryBefore)
        XCTAssertEqual(primaryAfter.functions, primaryBefore.functions)
        XCTAssertEqual(primaryAfter.instructions, primaryBefore.instructions)
        XCTAssertEqual(primaryAfter.sections, primaryBefore.sections)
        XCTAssertEqual(primaryAfter.sourceLines, primaryBefore.sourceLines)
        XCTAssertEqual(primaryAfter.hexBytes, primaryBefore.hexBytes)
        XCTAssertEqual(primaryAfter.imageBytes, primaryBefore.imageBytes)
    }

    // MARK: - Re-analysis preserves sibling images

    /// Package-byte recovery analyzes a temporary THIN Mach-O, whose fresh identity naturally has
    /// no universal slice index. The splice must restore the durable index so a later reanalysis
    /// against the original universal container still selects the same architecture.
    @MainActor
    func testRecoveredReanalysisPreservesSelectedSliceIndex() throws {
        let (url, _) = try primaryFixtureURL()
        var snapshot = try AnalysisEngine().analyze(url: url)
        let entry = try XCTUnwrap(snapshot.functions.first?.startAddress)
        let selectedSliceIndex = 3
        snapshot.binaries[0].selectedSliceIndex = selectedSliceIndex
        XCTAssertFalse(snapshot.imageBytes.isEmpty)

        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let store = WorkspaceStore(
            workspaceName: "Recovered Slice", snapshot: snapshot,
            engine: AnalysisEngine(), autosaveScheduler: nil
        )
        store.withSynchronousReanalysis {
            store.setMarkAsProcedure(entry, true)
        }

        XCTAssertEqual(store.snapshot.binary(in: .primary)?.selectedSliceIndex,
                       selectedSliceIndex)
    }

    /// Re-analyzing the primary image (a mark-as-code/data edit) must leave a SIBLING image's
    /// identity, derived products, breakpoint state, and authoring untouched. This is the
    /// highest-blast-radius seam: a naive re-flow rebuilds the whole snapshot from the primary
    /// and would drop every other image.
    @MainActor
    func testReanalysisPreservesSiblingImageAuthoringAndSlotIdentity() throws {
        let (url, _) = try primaryFixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var snapshot = try AnalysisEngine().analyze(url: url)
        let entry = try XCTUnwrap(snapshot.functions.first?.startAddress)
        let primaryBreakpoint = try XCTUnwrap(snapshot.instructions.first?.address)
        snapshot.mutateAnalysis(in: .primary) { analysis in
            analysis.instructions = analysis.instructions.map { row in
                guard row.address == primaryBreakpoint else { return row }
                var copy = row
                copy.hasBreakpoint = true
                return copy
            }
        }

        // Graft a second image with deliberately distinct derived products and breakpoint state
        // at a VA that collides with the primary.
        let siblingSlot = ImageSlot(rawValue: 1)
        var siblingBinary = image(slot: siblingSlot)
        siblingBinary.originalPathBookmark = Data([0xB0, 0x0B])
        siblingBinary.selectedSliceIndex = 3
        siblingBinary.metadata.uuid = "11111111-2222-3333-4444-555555555555"

        var siblingAnalysis = ImageAnalysis()
        siblingAnalysis.functions = [
            FunctionSummary(id: UUID(), name: "sibling_entry", startAddress: entry,
                            endAddress: entry + 8, confidence: 0.75),
        ]
        siblingAnalysis.instructions = [
            InstructionRow(address: entry, bytes: "aa bb cc dd", mnemonic: "sibling_a",
                           operands: "x0", hasBreakpoint: false, comment: "keep-a"),
            InstructionRow(address: entry + 4, bytes: "11 22 33 44", mnemonic: "sibling_b",
                           operands: "x1", hasBreakpoint: true, comment: "keep-b"),
        ]
        siblingAnalysis.hexBytes = Data([0x51, 0x52, 0x53])
        siblingAnalysis.imageBytes = Data([0xA1, 0xA2, 0xA3, 0xA4])
        siblingAnalysis.objcSelectors = [entry: "siblingSelector:"]
        siblingAnalysis.objcClasses = [ObjCClass(
            name: "SiblingClass", superclassName: "NSObject", adoptedProtocols: ["Keeping"],
            classMethods: [], instanceMethods: [], ivars: [], properties: []
        )]
        siblingAnalysis.objcCategories = [ObjCCategory(
            name: "SiblingCategory", className: "SiblingClass", classMethods: [],
            instanceMethods: [], adoptedProtocols: [], properties: []
        )]
        siblingAnalysis.swiftTypes = [SwiftTypeDescriptor(
            kind: .struct, name: "SiblingType", fields: [SwiftField(name: "value", typeName: "Int")]
        )]
        siblingAnalysis.swiftConformances = [
            SwiftConformance(typeName: "SiblingType", protocolName: "Keeping"),
        ]
        siblingAnalysis.diagnostics = [AnalysisDiagnostic(
            severity: .warning, address: entry + 4, kind: .loaderTruncation,
            message: "sibling diagnostic must survive"
        )]
        snapshot.insertImage(binary: siblingBinary, analysis: siblingAnalysis)
        snapshot.addressOverrides[ImageAddress(slot: siblingSlot, address: entry)] = AddressOverride(customName: "siblingKeep")

        let siblingAnalysisBefore = try XCTUnwrap(snapshot.analysis(in: siblingSlot))
        let siblingBinaryBefore = try XCTUnwrap(snapshot.binary(in: siblingSlot))

        let store = WorkspaceStore(workspaceName: "Siblings", snapshot: snapshot, engine: AnalysisEngine())
        // Trigger a structural re-analysis of the PRIMARY image.
        store.withSynchronousReanalysis {
            store.setMarkAsProcedure(entry, true)
        }
        let result = store.snapshot
        let siblingAnalysisAfter = try XCTUnwrap(result.analysis(in: siblingSlot))

        // The sibling's complete identity and representative derived products survive byte-for-byte.
        XCTAssertEqual(result.binary(in: siblingSlot), siblingBinaryBefore)
        XCTAssertEqual(siblingAnalysisAfter.functions, siblingAnalysisBefore.functions)
        XCTAssertEqual(siblingAnalysisAfter.instructions, siblingAnalysisBefore.instructions)
        XCTAssertEqual(siblingAnalysisAfter.imageBytes, siblingAnalysisBefore.imageBytes)
        XCTAssertEqual(siblingAnalysisAfter.hexBytes, siblingAnalysisBefore.hexBytes)
        XCTAssertEqual(siblingAnalysisAfter.objcSelectors, siblingAnalysisBefore.objcSelectors)
        XCTAssertEqual(siblingAnalysisAfter.objcClasses, siblingAnalysisBefore.objcClasses)
        XCTAssertEqual(siblingAnalysisAfter.objcCategories, siblingAnalysisBefore.objcCategories)
        XCTAssertEqual(siblingAnalysisAfter.swiftTypes, siblingAnalysisBefore.swiftTypes)
        XCTAssertEqual(siblingAnalysisAfter.swiftConformances, siblingAnalysisBefore.swiftConformances)
        XCTAssertEqual(siblingAnalysisAfter.diagnostics, siblingAnalysisBefore.diagnostics)

        // The sibling's authoring survived the primary re-flow, still keyed to its slot.
        XCTAssertEqual(result.addressOverrides[ImageAddress(slot: siblingSlot, address: entry)]?.customName,
                       "siblingKeep",
                       "re-analyzing the primary image must not drop a sibling image's overrides")
        // The primary image kept slot 0 across the splice (durable identity, not re-minted).
        XCTAssertEqual(result.binaries.first?.slot, .primary)
        // The primary edit landed in the primary slot.
        XCTAssertEqual(result.addressOverrides[.primary(entry)]?.markAsProcedure, true)
        // Breakpoint restoration is scoped to the re-analyzed bucket; sibling rows stayed exact.
        XCTAssertEqual(result.analysis(in: .primary)?.instructions.first(where: {
            $0.address == primaryBreakpoint
        })?.hasBreakpoint, true)
    }

    // MARK: - Persistence: v25 round-trip + collision

    /// Two overrides at the same address in different slots must survive a full save→load through
    /// the v25 schema. If the widened UNIQUE(workspace_id, image_slot, address) index were still
    /// narrow, the second insert would collide and abort the whole save.
    func testTwoSlotOverridesRoundTripThroughDatabase() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        var snapshot = WorkspaceSnapshot(binaries: [image(slot: .primary), image(slot: ImageSlot(rawValue: 1))], functions: [], instructions: [], xrefs: [], hexBytes: Data())
        snapshot.addressOverrides = [
            .primary(collidingAddress): AddressOverride(customName: "slot0"),
            ImageAddress(slot: ImageSlot(rawValue: 1), address: collidingAddress): AddressOverride(customName: "slot1"),
        ]
        // The single save inserts TWO rows at the same (workspace, address) under different
        // slots — under the old narrow UNIQUE(workspace_id, address) index the second row
        // would abort the whole save.
        let workspace = try database.saveSnapshot(workspaceName: "TwoSlot", snapshot: snapshot)

        let reloaded = try XCTUnwrap(try database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id)))
        XCTAssertEqual(reloaded.addressOverrides[.primary(collidingAddress)]?.customName, "slot0")
        XCTAssertEqual(reloaded.addressOverrides[ImageAddress(slot: ImageSlot(rawValue: 1), address: collidingAddress)]?.customName, "slot1")
    }

    /// The fresh v25 schema must carry `image_slot` on every authoring table and a WIDE UNIQUE
    /// index that includes it — the guarantee that fresh installs and migrated DBs converge.
    func testFreshSchemaIsImageAware() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        for table in ["address_overrides", "manual_xrefs", "bookmarks", "segment_overrides", "binaries"] {
            XCTAssertTrue(try database.columnNames(in: table).contains("image_slot"),
                          "\(table) must have image_slot in v25")
        }
        XCTAssertTrue(try database.columnNames(in: "workspaces").contains("next_image_slot"))
        XCTAssertTrue(try database.columnNames(in: "workspace_sessions").contains("focused_image_slot"))
        XCTAssertEqual(
            try database.indexColumns(of: "idx_binaries_workspace_image_slot"),
            ["workspace_id", "image_slot"]
        )
        XCTAssertTrue(try database.indexColumns(of: "idx_address_overrides_workspace_address").contains("image_slot"),
                      "the address-override UNIQUE index must include image_slot")
        XCTAssertTrue(try database.indexColumns(of: "idx_bookmarks_workspace_address").contains("image_slot"))
    }

    /// Re-applying the schema must be a no-op (idempotent DROP INDEX / CREATE). This guards the
    /// index-resurrection fix: a second open must not fail or leave a stale narrow index.
    func testApplySchemaIsIdempotent() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        XCTAssertNoThrow(try database.applySchema())
        XCTAssertTrue(try database.indexColumns(of: "idx_address_overrides_workspace_address").contains("image_slot"))
    }

    /// The genuine v24→v25 migration: a fabricated NARROW pre-v25 database (image_slot absent, the
    /// old narrow UNIQUE index present) must migrate to the wide form WITHOUT losing its rows and
    /// WITHOUT resurrecting the narrow index. This is the trap the design panel ranked highest.
    func testMigrationFromNarrowV24WidensIndexAndPreservesData() throws {
        let database = try WorkspaceDatabase.inMemory()
        // Materialize the v24 tables needed by this focused fixture, including the historical
        // symbols prerequisite. Current-schema validation must not accept a missing core table.
        // The symbols raw-linkage column and image-aware override/index shape are migrated.
        try database.executeRawForTesting("""
            CREATE TABLE workspaces (
              id INTEGER PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
              created_at TEXT NOT NULL, modified_at TEXT NOT NULL
            );
            CREATE TABLE address_overrides (
              id INTEGER PRIMARY KEY,
              workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
              address INTEGER NOT NULL, custom_name TEXT, custom_comment TEXT, tag TEXT, color_tag TEXT,
              is_data INTEGER NOT NULL DEFAULT 0, signature_json TEXT, applied_type_name TEXT,
              switch_hint_json TEXT, operand_format TEXT, created_at TEXT NOT NULL, modified_at TEXT NOT NULL,
              mark_as_procedure INTEGER NOT NULL DEFAULT 0, data_shape_json TEXT,
              is_undefined INTEGER NOT NULL DEFAULT 0, patch_json TEXT, register_names_json TEXT, local_label TEXT
            );
            CREATE UNIQUE INDEX idx_address_overrides_workspace_address ON address_overrides(workspace_id, address);
            CREATE TABLE binaries (
              id INTEGER PRIMARY KEY, uuid TEXT NOT NULL UNIQUE,
              workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
              name TEXT NOT NULL, path TEXT NOT NULL, original_path_bookmark BLOB,
              kind TEXT NOT NULL, architecture TEXT NOT NULL, file_hash TEXT NOT NULL,
              file_size INTEGER NOT NULL, hex_bytes BLOB, is_bundle INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE symbols (
              id INTEGER PRIMARY KEY, uuid TEXT NOT NULL UNIQUE,
              binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE,
              name TEXT NOT NULL, address INTEGER, kind TEXT NOT NULL, library_name TEXT
            );
            CREATE TABLE functions (
              id INTEGER PRIMARY KEY, uuid TEXT NOT NULL UNIQUE,
              binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE,
              start_address INTEGER NOT NULL, end_address INTEGER,
              symbol_name TEXT, demangled_name TEXT, confidence REAL NOT NULL DEFAULT 0.0
            );
            CREATE TABLE exports (
              id INTEGER PRIMARY KEY, uuid TEXT NOT NULL UNIQUE,
              binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE,
              name TEXT NOT NULL, address INTEGER, source TEXT NOT NULL
            );
            CREATE TABLE instructions (
              id INTEGER PRIMARY KEY,
              function_id INTEGER NOT NULL REFERENCES functions(id) ON DELETE CASCADE,
              address INTEGER NOT NULL, bytes BLOB NOT NULL,
              mnemonic TEXT NOT NULL, operands TEXT NOT NULL,
              has_breakpoint INTEGER NOT NULL DEFAULT 0, comment TEXT, ir_json BLOB
            );
            INSERT INTO workspaces (id, uuid, name, created_at, modified_at)
              VALUES (1, '24000000-0000-0000-0000-000000000024', 'Legacy', '2020-01-01T00:00:00.000Z', '2020-01-01T00:00:00.000Z');
            INSERT INTO binaries (id, uuid, workspace_id, name, path, kind, architecture, file_hash, file_size)
              VALUES (10, '6B29FC40-CA47-1067-B31D-00DD010662DA', 1, 'a', '/tmp/a', 'executable', 'arm64', 'h1', 1),
                     (11, '6B29FC40-CA47-1067-B31D-00DD010662DB', 1, 'b', '/tmp/b', 'executable', 'arm64', 'h2', 1);
            INSERT INTO symbols (id, uuid, binary_id, name, address, kind)
              VALUES (20, '24000000-0000-0000-0000-000000000020', 10, '_legacy', 4294967300, 'defined');
            INSERT INTO address_overrides (workspace_id, address, custom_name, created_at, modified_at)
              VALUES (1, 4294967300, 'legacyName', '2020-01-01T00:00:00.000Z', '2020-01-01T00:00:00.000Z');
            """)
        try database.setUserVersionForTesting(24)

        // Open path: applySchema takes the v24→v25 branch.
        try database.applySchema()

        XCTAssertEqual(try database.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try database.columnNames(in: "address_overrides").contains("image_slot"),
                      "migration must add image_slot")
        XCTAssertTrue(try database.columnNames(in: "binaries").contains("selected_slice_index"),
                      "migration must add the v26 selected_slice_index column")
        XCTAssertEqual(try database.indexColumns(of: "idx_address_overrides_workspace_address"),
                       ["workspace_id", "image_slot", "address"],
                       "the narrow index must be REPLACED by the wide one, not resurrected")
        // The legacy row survived and defaulted to the primary slot.
        let overrides = try database.addressOverrides(workspaceID: 1)
        XCTAssertEqual(overrides.count, 1)
        XCTAssertEqual(overrides.first?.customName, "legacyName")
        XCTAssertEqual(overrides.first?.imageSlot, 0, "legacy authoring defaults to the primary image")
        // Existing binaries are numbered by insertion order within the workspace: first = slot 0.
        let binaries = try database.binaries(workspaceID: 1)
        XCTAssertEqual(binaries.map(\.imageSlot), [0, 1],
                       "migration must backfill slots by insertion order (first binary = primary)")
        XCTAssertTrue(try database.columnNames(in: "symbols").contains("raw_linkage_name"))
        XCTAssertEqual(try database.scalarIntForTesting("""
            SELECT COUNT(*) FROM symbols WHERE id = 20 AND binary_id = 10
              AND name = '_legacy' AND address = 4294967300 AND raw_linkage_name IS NULL;
            """), 1)
        XCTAssertNoThrow(try database.applySchema(), "The migrated shape must also pass current-schema reopen validation.")
    }

    // MARK: - Byte-identity: single-image packages unchanged

    /// A single-image override entry must encode WITHOUT an `imageSlot` field (omit-when-0), so a
    /// v25 build writes byte-identical package JSON to the pre-image-aware format, and a legacy
    /// entry with no slot decodes to the primary image.
    func testSingleImageOverrideEntryOmitsSlotAndLegacyDecodesToPrimary() throws {
        let entry = AddressOverrideEntry(address: 0x1000, override: AddressOverride(customName: "n"))
        let json = try String(data: JSONEncoder().encode(entry), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("imageSlot"),
                       "a primary-slot entry must omit imageSlot for byte-identical single-image packages")

        // A legacy entry (no imageSlot key) decodes to the primary slot.
        let legacyJSON = #"{"address":4096,"override":{"customName":"n"}}"#
        let decoded = try JSONDecoder().decode(AddressOverrideEntry.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.imageSlot, .primary)

        // A non-primary entry DOES carry the slot.
        let sibling = AddressOverrideEntry(address: 0x1000, imageSlot: ImageSlot(rawValue: 2), override: AddressOverride(customName: "n"))
        let siblingJSON = try String(data: JSONEncoder().encode(sibling), encoding: .utf8) ?? ""
        XCTAssertTrue(siblingJSON.contains("imageSlot"), "a non-primary entry must persist its slot")
    }

    // MARK: - Helpers

    private func image(slot: ImageSlot) -> BinaryImage {
        BinaryImage(id: UUID(), name: "img\(slot.rawValue)", path: "/tmp/img\(slot.rawValue)",
                    kind: "executable", architecture: "arm64", slot: slot)
    }

    /// A two-image store: slot 0 has 1 function, slot 1 has 2 — so focus is observable.
    @MainActor
    private func twoImageFocusStore() -> WorkspaceStore {
        var a = ImageAnalysis()
        a.functions = [FunctionSummary(id: UUID(), name: "a0", startAddress: 0x1000, endAddress: 0x1004, confidence: 1)]
        var b = ImageAnalysis()
        b.functions = [
            FunctionSummary(id: UUID(), name: "b0", startAddress: 0x2000, endAddress: 0x2004, confidence: 1),
            FunctionSummary(id: UUID(), name: "b1", startAddress: 0x2100, endAddress: 0x2104, confidence: 1),
        ]
        let snap = WorkspaceSnapshot(
            binaries: [image(slot: .primary), image(slot: ImageSlot(rawValue: 1))],
            analysisBySlot: [.primary: a, ImageSlot(rawValue: 1): b]
        )
        return WorkspaceStore(workspaceName: "Focus", snapshot: snap, engine: AnalysisEngine())
    }

    /// A two-image store whose functions and instructions deliberately share one VA. This is the
    /// only shape that can expose a delayed sheet accidentally rebinding its bare address after a
    /// focus switch: without the collision, an edit routed to the wrong slot can look harmless.
    @MainActor
    private func twoImageCollisionStore() -> WorkspaceStore {
        func analysis(named name: String) -> ImageAnalysis {
            var analysis = ImageAnalysis()
            analysis.functions = [FunctionSummary(
                id: UUID(), name: name, startAddress: collidingAddress,
                endAddress: collidingAddress + 4, confidence: 1
            )]
            analysis.instructions = [InstructionRow(
                address: collidingAddress, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "",
                hasBreakpoint: false, comment: name
            )]
            return analysis
        }

        let sibling = ImageSlot(rawValue: 1)
        let snapshot = WorkspaceSnapshot(
            binaries: [image(slot: .primary), image(slot: sibling)],
            analysisBySlot: [
                .primary: analysis(named: "image_a"),
                sibling: analysis(named: "image_b"),
            ]
        )
        return WorkspaceStore(
            workspaceName: "Colliding Editors", snapshot: snapshot,
            engine: AnalysisEngine(), autosaveScheduler: nil
        )
    }

    // MARK: - Phase 4: store-owned focus

    @MainActor
    func testFocusImageSwitchesFocusedAnalysisAndBinary() {
        let store = twoImageFocusStore()
        XCTAssertEqual(store.focusedImageSlot, .primary)
        XCTAssertEqual(store.focusedAnalysis?.functions.count, 1)

        store.focusImage(ImageSlot(rawValue: 1))
        XCTAssertEqual(store.focusedImageSlot, ImageSlot(rawValue: 1))
        XCTAssertEqual(store.focusedAnalysis?.functions.count, 2)
        XCTAssertEqual(store.focusedBinary?.slot, ImageSlot(rawValue: 1))
    }

    @MainActor
    func testActivatingBinarySidebarRowFocusesThatImage() throws {
        let store = twoImageFocusStore()
        let siblingID = try XCTUnwrap(store.snapshot.binary(in: ImageSlot(rawValue: 1))?.id)
        store.activateSidebarItem("binary:\(siblingID.uuidString)")
        XCTAssertEqual(store.focusedImageSlot, ImageSlot(rawValue: 1))
        XCTAssertEqual(store.focusedAnalysis?.functions.count, 2)
    }

    // MARK: - Phase 5: Load Additional Binary

    @MainActor
    func testNextImageSlotAllocatesMaxPlusOneAcrossNoncontiguousSlots() {
        let snap = WorkspaceSnapshot(
            binaries: [image(slot: .primary), image(slot: ImageSlot(rawValue: 7))],
            analysisBySlot: [.primary: ImageAnalysis(), ImageSlot(rawValue: 7): ImageAnalysis()]
        )
        let store = WorkspaceStore(workspaceName: "Slots", snapshot: snap, engine: AnalysisEngine())
        XCTAssertEqual(store.nextImageSlot(), ImageSlot(rawValue: 8))
    }

    @MainActor
    func testLoadAdditionalBinaryInsertsNewImageFocusesItAndPreservesSibling() async {
        func insn(_ address: UInt64) -> InstructionRow {
            InstructionRow(address: address, bytes: "", mnemonic: "nop", operands: "",
                           hasBreakpoint: false, comment: nil)
        }
        var a = ImageAnalysis()
        a.functions = [FunctionSummary(id: UUID(), name: "a", startAddress: 0x1000, endAddress: 0x1004, confidence: 1)]
        a.instructions = [insn(0x1000)]
        let existing = WorkspaceSnapshot(binaries: [image(slot: .primary)], analysisBySlot: [.primary: a])

        // The "second binary" the engine returns is image-local at .primary.
        var b = ImageAnalysis()
        b.functions = [FunctionSummary(id: UUID(), name: "b", startAddress: 0x2000, endAddress: 0x2004, confidence: 1)]
        b.instructions = [insn(0x2000)]
        let providerResult = WorkspaceSnapshot(binaries: [image(slot: .primary)], analysisBySlot: [.primary: b])

        let store = WorkspaceStore(workspaceName: "LAB", snapshot: existing,
                                   engine: SingleImageScriptedProvider(providerResult))
        await store.loadAdditionalBinary(url: URL(fileURLWithPath: "/tmp/second-binary"))

        let newSlot = ImageSlot(rawValue: 1)
        XCTAssertEqual(store.snapshot.binaries.count, 2, "the new image was inserted alongside the existing one")
        XCTAssertNotNil(store.snapshot.binary(in: newSlot))
        XCTAssertEqual(store.focusedImageSlot, newSlot, "focus moves to the newly loaded image")
        XCTAssertEqual(store.focusedAnalysis?.functions.first?.name, "b")
        // The pre-existing primary image survives untouched.
        XCTAssertEqual(store.snapshot.analysis(in: .primary)?.functions.first?.name, "a")
    }

    @MainActor
    func testFocusImageRejectsNonexistentSlot() {
        let store = twoImageFocusStore()
        store.focusImage(ImageSlot(rawValue: 99))
        XCTAssertEqual(store.focusedImageSlot, .primary, "focusing a nonexistent slot is a no-op")
    }

    @MainActor
    func testFocusedSlotFallsBackToPrimaryWhenFocusedImageRemoved() {
        let store = twoImageFocusStore()
        store.focusImage(ImageSlot(rawValue: 1))
        XCTAssertEqual(store.focusedImageSlot, ImageSlot(rawValue: 1))
        // Drop the focused image (e.g., a restore/reanalysis that no longer contains it).
        store.snapshot.removeImage(in: ImageSlot(rawValue: 1))
        XCTAssertEqual(store.focusedImageSlot, .primary, "focus must fall back when its image vanishes")
        XCTAssertEqual(store.focusedAnalysis?.functions.count, 1)
    }

    @MainActor
    func testFlatSnapshotProjectionsStayPrimaryRegardlessOfFocus() {
        let store = twoImageFocusStore()
        store.focusImage(ImageSlot(rawValue: 1))
        // The snapshot's flat projections must NOT follow UI focus — golden/headless/scripting
        // read them and must stay deterministic on the primary image.
        XCTAssertEqual(store.snapshot.functions.count, 1, "flat projection stays primary")
        XCTAssertEqual(store.snapshot.primarySlot, .primary)
    }

    // MARK: - Phase 4.3: image-qualified delayed state

    /// Opening an editor captures image B. A later focus switch to image A must not reinterpret the
    /// draft's colliding bare VA: both rename and signature commits still belong to B.
    @MainActor
    func testDelayedRenameAndSignatureRequestsCommitToOpeningSlot() throws {
        let sibling = ImageSlot(rawValue: 1)
        let store = twoImageCollisionStore()

        store.focusImage(sibling)
        store.selectedAddress = collidingAddress
        store.beginRenameAtSelection()
        let renameRequest = try XCTUnwrap(store.overrideEditorRequest)
        XCTAssertEqual(renameRequest.imageSlot, sibling)

        store.focusImage(.primary)
        store.commitOverrideEditor(renameRequest, text: "renamed_in_b")

        XCTAssertEqual(store.snapshot.addressOverrides[
            ImageAddress(slot: sibling, address: collidingAddress)
        ]?.customName, "renamed_in_b")
        XCTAssertNil(store.snapshot.addressOverrides[.primary(collidingAddress)]?.customName)

        store.focusImage(sibling)
        store.selectedAddress = collidingAddress
        store.beginSignatureEditAtSelection()
        var signatureDraft = try XCTUnwrap(store.signatureEditorRequest)
        XCTAssertEqual(signatureDraft.imageSlot, sibling)
        signatureDraft.returnType = "uint64_t"

        store.focusImage(.primary)
        store.commitSignatureEditor(signatureDraft)

        XCTAssertEqual(store.snapshot.addressOverrides[
            ImageAddress(slot: sibling, address: collidingAddress)
        ]?.signature?.returnType, "uint64_t")
        XCTAssertNil(store.snapshot.addressOverrides[.primary(collidingAddress)]?.signature)
    }

    /// Structural editor requests exercise the same temporal identity rule. Patch/assemble types
    /// currently live in the UI slice, so this test asserts their externally observable contract:
    /// opening on B and applying after focusing A still writes B's qualified override.
    @MainActor
    func testDelayedStructuralRequestsCommitToOpeningSlot() throws {
        let sibling = ImageSlot(rawValue: 1)
        let store = twoImageCollisionStore()

        store.focusImage(sibling)
        store.selectedAddress = collidingAddress
        store.beginSwitchHintEditAtSelection()
        var switchDraft = try XCTUnwrap(store.switchHintEditorRequest)
        XCTAssertEqual(switchDraft.imageSlot, sibling)
        switchDraft.tableBaseText = collidingAddress.hexAddress
        switchDraft.entryCountText = "2"

        store.focusImage(.primary)
        store.commitSwitchHintEditor(switchDraft)
        XCTAssertEqual(store.snapshot.addressOverrides[
            ImageAddress(slot: sibling, address: collidingAddress)
        ]?.switchHint?.entryCount, 2)
        XCTAssertNil(store.snapshot.addressOverrides[.primary(collidingAddress)]?.switchHint)

        store.focusImage(sibling)
        store.selectedAddress = collidingAddress
        store.beginMakeDataAtSelection()
        var dataDraft = try XCTUnwrap(store.dataShapeEditorRequest)
        XCTAssertEqual(dataDraft.imageSlot, sibling)
        dataDraft.shape = .array
        dataDraft.elementType = "uint32_t"
        dataDraft.countText = "3"

        store.focusImage(.primary)
        XCTAssertTrue(store.commitDataShapeEditor(dataDraft))
        XCTAssertEqual(store.snapshot.addressOverrides[
            ImageAddress(slot: sibling, address: collidingAddress)
        ]?.dataShape?.elementCount, 3)
        XCTAssertNil(store.snapshot.addressOverrides[.primary(collidingAddress)]?.dataShape)

        store.focusImage(sibling)
        store.selectedAddress = collidingAddress
        store.perform(.patchBytes)
        let patchRequest = try XCTUnwrap(store.pendingPatchBytesRequest)
        store.focusImage(.primary)
        XCTAssertTrue(store.patchBytes(patchRequest, hex: "aa bb cc dd"))
        XCTAssertEqual(store.snapshot.addressOverrides[
            ImageAddress(slot: sibling, address: collidingAddress)
        ]?.patch?.bytes, [0xAA, 0xBB, 0xCC, 0xDD])
        XCTAssertNil(store.snapshot.addressOverrides[.primary(collidingAddress)]?.patch)

        let assembleStore = twoImageCollisionStore()
        assembleStore.focusImage(sibling)
        assembleStore.selectedAddress = collidingAddress
        assembleStore.perform(.assembleInstruction)
        let assembleRequest = try XCTUnwrap(assembleStore.pendingAssembleRequest)
        assembleStore.focusImage(.primary)
        XCTAssertTrue(assembleStore.assemble(assembleRequest, text: "nop"))
        XCTAssertEqual(assembleStore.snapshot.addressOverrides[
            ImageAddress(slot: sibling, address: collidingAddress)
        ]?.patch?.bytes, BytePatch.arm64NOP.bytes)
        XCTAssertNil(assembleStore.snapshot.addressOverrides[.primary(collidingAddress)]?.patch)
    }

    /// Type definitions are workspace-global today, but their delayed editor still captures the
    /// opening image so the request remains correctly identified if the catalog becomes per-image.
    @MainActor
    func testTypeEditorRequestCapturesOpeningSlot() throws {
        let sibling = ImageSlot(rawValue: 1)
        let store = twoImageCollisionStore()
        store.focusImage(sibling)

        store.beginTypeDefinition()
        let draft = try XCTUnwrap(store.typeEditorRequest)

        XCTAssertEqual(draft.imageSlot, sibling)
    }

    // MARK: - Phase 4.3: focused-image persistence

    @MainActor
    func testFocusedImageSlotRoundTripsThroughWorkspaceSaveAndRestore() throws {
        let sibling = ImageSlot(rawValue: 1)
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let store = twoImageFocusStore()
        store.focusImage(sibling)

        let persisted = try store.saveWorkspace(to: database)
        XCTAssertEqual(persisted.session.focusedImageSlot, sibling)

        let workspaceID = try XCTUnwrap(persisted.workspace.id)
        let restored = try XCTUnwrap(WorkspaceStore.restored(
            workspaceID: workspaceID, from: database
        ))
        XCTAssertEqual(restored.focusedImageSlotStorage, sibling)
        XCTAssertEqual(restored.focusedImageSlot, sibling)
    }

    /// A session may outlive the binary it once focused (for example after package repair). Restore
    /// must validate against the installed snapshot and store `.primary`, not retain a stale slot.
    @MainActor
    func testRestoreClampsAbsentFocusedImageSlotToPrimary() throws {
        let absent = ImageSlot(rawValue: 9)
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let snapshot = WorkspaceSnapshot(
            binaries: [image(slot: .primary)],
            analysisBySlot: [.primary: ImageAnalysis()]
        )
        let persisted = try database.createWorkspaceState(
            workspaceName: "Stale Focus",
            snapshot: snapshot,
            selectedSidebarItemID: nil,
            selectedAddress: nil,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: "",
            focusedImageSlot: absent
        )

        let restored = try XCTUnwrap(WorkspaceStore.restored(
            workspaceID: try XCTUnwrap(persisted.workspace.id), from: database
        ))
        XCTAssertEqual(restored.focusedImageSlotStorage, .primary)
        XCTAssertEqual(restored.focusedImageSlot, .primary)
    }

    /// A real, loadable thin arm64 Mach-O whose __TEXT is based at 0x1_0000_0000 (so a second
    /// image would collide) — reused from the portability fixture builder.
    private func primaryFixtureURL() throws -> (url: URL, byteCount: Int) {
        var code = Data()
        for _ in 0..<64 { code.append(contentsOf: [0x1f, 0x20, 0x03, 0xd5]) } // nop
        code.append(contentsOf: [0xc0, 0x03, 0x5f, 0xd6]) // ret
        let fixture = MachOFixture.makeExecutable(code: code)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageIdentityFixture-\(UUID().uuidString)")
        try fixture.bytes.write(to: url)
        return (url, fixture.bytes.count)
    }
}

/// A minimal provider that returns a fixed single-image snapshot — for exercising
/// `loadAdditionalBinary` without a real toolchain analysis.
private final class SingleImageScriptedProvider: AnalysisProviding, @unchecked Sendable {
    private let result: WorkspaceSnapshot
    init(_ result: WorkspaceSnapshot) { self.result = result }

    func analyze(url: URL, requestedSliceIndex: Int?, overrides: [UInt64: AddressOverride],
                 cancellation: AnalysisCancellationToken) throws -> WorkspaceSnapshot { result }

    func openBinary(url: URL, requestedSliceIndex: Int?, overrides: [UInt64: AddressOverride],
                    cancellation: AnalysisCancellationToken) async throws -> WorkspaceSnapshot { result }
}
