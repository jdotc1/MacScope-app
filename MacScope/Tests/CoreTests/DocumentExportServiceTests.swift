import XCTest
@testable import MacScope

/// Tier 3 — Export disassembly listing + pseudocode to text.
///
/// Exercises the pure `DocumentExportService`: it must render a known snapshot's
/// LISTING to the expected plain text (addresses, bytes, mnemonics, a section-header
/// row, an applied custom name as a label, an inline comment override, a prefix
/// comment row, a mark-as-data directive) and a function's PSEUDOCODE to the expected
/// text — all deterministically, with no file I/O (assertions are on the returned
/// `String`).
final class DocumentExportServiceTests: XCTestCase {

    private func insn(
        _ address: UInt64,
        bytes: String = "",
        _ mnemonic: String = "nop",
        _ operands: String = "",
        comment: String? = nil
    ) -> InstructionRow {
        InstructionRow(address: address, bytes: bytes, mnemonic: mnemonic, operands: operands,
                       hasBreakpoint: false, comment: comment)
    }

    private func snapshot(
        instructions: [InstructionRow],
        functions: [FunctionSummary] = [],
        symbols: [SymbolSummary] = [],
        sections: [SectionSummary] = [],
        overrides: [UInt64: AddressOverride] = [:]
    ) -> WorkspaceSnapshot {
        var snap = WorkspaceSnapshot(binaries: [], functions: functions,
                                     instructions: instructions, xrefs: [], hexBytes: Data())
        snap.symbols = symbols
        snap.sections = sections
        snap.addressOverrides = Dictionary(uniqueKeysWithValues: overrides.map { (ImageAddress.primary($0.key), $0.value) })
        return snap
    }

    private func section(_ name: String, _ address: UInt64, executable: Bool = true) -> SectionSummary {
        SectionSummary(id: UUID(), name: name, address: address, size: 0x100,
                       fileOffset: 0, isExecutable: executable)
    }

    private func function(_ name: String, _ start: UInt64, _ end: UInt64) -> FunctionSummary {
        FunctionSummary(id: UUID(), name: name, startAddress: start, endAddress: end, confidence: 1)
    }

    // MARK: - Listing export

    /// A single snapshot that hits every listing row form: a section header, a label at
    /// the (custom-named) function start, a plain instruction, an instruction with an
    /// inline comment override, a multi-line prefix comment row, and a mark-as-data row
    /// rendered as a `.long` directive.
    func testRenderListingMatchesExpectedText() {
        let snap = snapshot(
            instructions: [
                insn(0x1000, bytes: "fd 7b bf a9", "stp", "x29, x30, [sp, #-0x10]!"),
                insn(0x1004, bytes: "08 00 80 d2", "mov", "x8, #0"),
                insn(0x1008, bytes: "1f 20 03 d5", "nop"),
                insn(0x100C, bytes: "c0 03 5f d6", "ret"),
            ],
            functions: [function("sub_1000", 0x1000, 0x1010)],
            sections: [section("__TEXT,__text", 0x1000)],
            overrides: [
                // Custom name on the function start -> the label row uses it.
                0x1000: AddressOverride(customName: "parse_header"),
                // Short comment override -> inline (trailing) on the instruction row.
                0x1004: AddressOverride(customComment: "zero the accumulator"),
                // Multi-line comment override -> own-line prefix comment row(s).
                0x1008: AddressOverride(customComment: "block A\nblock B"),
                // Mark as data -> the bytes render as a .long directive.
                0x100C: AddressOverride(isData: true),
            ]
        )

        let text = DocumentExportService().renderListing(snapshot: snap)

        let expected = """
        ; ============ __TEXT,__text (0x0000000000001000) ============
        parse_header:
        0x0000000000001000  fd 7b bf a9               stp        x29, x30, [sp, #-0x10]!
        0x0000000000001004  08 00 80 d2               mov        x8, #0  ; zero the accumulator
        ; block A
        ; block B
        0x0000000000001008  1f 20 03 d5               nop
        0x000000000000100c  c0 03 5f d6               .long      0xd65f03c0
        """
        XCTAssertEqual(text, expected)
    }

    /// An empty snapshot exports an empty string (no rows, no crash).
    func testRenderListingEmptySnapshot() {
        let text = DocumentExportService().renderListing(snapshot: snapshot(instructions: []))
        XCTAssertEqual(text, "")
    }

    /// The decoder's own comment is exported (inline) when the user set no override.
    func testRenderListingUsesDecoderCommentWhenNoOverride() {
        let snap = snapshot(
            instructions: [insn(0x2000, bytes: "1f 20 03 d5", "nop", comment: "padding")]
        )
        let text = DocumentExportService().renderListing(snapshot: snap)
        XCTAssertEqual(text, "0x0000000000002000  1f 20 03 d5               nop  ; padding")
    }

    func testListingExportPreservesAlignmentDirective() {
        let snap = snapshot(
            instructions: [insn(0x1004, bytes: "1f 20 03 d5", "nop")],
            overrides: [0x1004: AddressOverride(
                dataShape: DataShapeOverride(kind: .alignment, alignment: 16)
            )]
        )
        let text = DocumentExportService().renderListing(snapshot: snap)
        XCTAssertTrue(text.contains(".balign"), text)
        XCTAssertTrue(text.contains("16  ; pad 12"), text)
        XCTAssertFalse(text.contains(".long"), text)
        XCTAssertFalse(text.contains("nop"), text)
    }

    func testListingExportPreservesUndefinedInterpretation() {
        let snap = snapshot(
            instructions: [insn(0x1000, bytes: "1f 20 03 d5", "nop", comment: "decoder comment")],
            overrides: [0x1000: AddressOverride(isUndefined: true)]
        )
        let text = DocumentExportService().renderListing(snapshot: snap)
        XCTAssertTrue(text.contains(".long"), text)
        XCTAssertTrue(text.contains("0xd503201f  ; undefined"), text)
        XCTAssertFalse(text.contains("nop"), text)
        XCTAssertFalse(text.contains("decoder comment"), text)
    }

    // MARK: - Pseudocode export

    /// A function's pseudocode renders to the printer's exact text (single function).
    func testRenderPseudocodeForSelectedFunction() {
        let rows = [
            insn(0x1000_00040, bytes: "00 00 00 00", "udf", "#0", comment: "Deliberate undefined instruction")
        ]
        let snap = snapshot(
            instructions: rows,
            functions: [function("_trap", 0x1000_00040, 0x1000_00044)]
        )

        let text = DocumentExportService().renderPseudocode(snapshot: snap, selectedAddress: 0x1000_00040)

        XCTAssertEqual(
            text,
            """
            int64_t _trap(void) {
                // entry 0x0000000100000040; no stack frame; calls none
                __unknown("udf", "#0"); // Deliberate undefined instruction
            }
            """
        )
    }

    /// A custom function name override flows into the exported pseudocode signature.
    func testRenderPseudocodeHonorsCustomFunctionName() {
        let rows = [
            insn(0x1000_00040, bytes: "00 00 00 00", "udf", "#0", comment: "trap")
        ]
        let snap = snapshot(
            instructions: rows,
            functions: [function("_trap", 0x1000_00040, 0x1000_00044)],
            overrides: [0x1000_00040: AddressOverride(customName: "abort_now")]
        )

        let text = DocumentExportService().renderPseudocode(snapshot: snap, selectedAddress: nil)
        XCTAssertTrue(
            text.hasPrefix("int64_t abort_now(void) {"),
            "expected the custom name in the signature, got:\n\(text)"
        )
    }

    /// Whole-binary scope exports every function, in ascending start-address order,
    /// separated by a blank line.
    func testRenderAllPseudocodeCoversEveryFunctionInOrder() {
        let rows = [
            insn(0x2000, bytes: "00 00 00 00", "udf", "#0", comment: "two"),
            insn(0x1000, bytes: "00 00 00 00", "udf", "#0", comment: "one"),
        ]
        let snap = snapshot(
            instructions: rows,
            functions: [
                function("_beta", 0x2000, 0x2004),
                function("_alpha", 0x1000, 0x1004),
            ]
        )

        let text = DocumentExportService().renderAllPseudocode(snapshot: snap)
        let blocks = text.components(separatedBy: "\n\n")
        XCTAssertEqual(blocks.count, 2)
        // _alpha (0x1000) sorts before _beta (0x2000).
        XCTAssertTrue(blocks[0].hasPrefix("int64_t _alpha(void) {"), blocks[0])
        XCTAssertTrue(blocks[1].hasPrefix("int64_t _beta(void) {"), blocks[1])
    }

    func testRenderObjectiveCHeaderEmitsInterfacesAndHandlesEmpty() {
        let service = DocumentExportService()
        // No recovered classes -> a friendly comment, never an empty/confusing file.
        XCTAssertTrue(service.renderObjectiveCHeader(snapshot: snapshot(instructions: []))
            .contains("No Objective-C classes"))

        // Populated -> the renderer's @interface blocks from snapshot.objcClasses.
        var snap = snapshot(instructions: [])
        snap.objcClasses = [
            ObjCClass(
                name: "Widget", superclassName: "NSObject", adoptedProtocols: ["NSCoding"],
                classMethods: [ObjCMethod(selector: "alloc", typeEncoding: "@16@0:8", isClassMethod: true)],
                instanceMethods: [ObjCMethod(selector: "count", typeEncoding: "Q16@0:8", isClassMethod: false)],
                ivars: [ObjCIvar(name: "_count", typeEncoding: "q")],
                properties: [ObjCProperty(name: "title", attributes: "T@\"NSString\",N,V_title")]
            )
        ]
        let header = service.renderObjectiveCHeader(snapshot: snap)
        XCTAssertTrue(header.contains("@interface Widget : NSObject <NSCoding>"), header)
        XCTAssertTrue(header.contains("+ (id)alloc;"), header)
        XCTAssertTrue(header.contains("_count;"), header)
        XCTAssertTrue(header.contains("@property"), header)
        XCTAssertTrue(header.contains("@end"), header)
    }

    /// End-to-end: analyzing a real ObjC binary populates snapshot.objcClasses (the
    /// loader → engine → snapshot thread the export command depends on) and the header export
    /// renders its recovered @interface blocks. `@MainActor` because `analyze(url:)` is isolated.
    @MainActor
    func testObjectiveCHeaderExportFromAnalyzedBinary() throws {
        let url = URL(fileURLWithPath: "/usr/bin/plutil")
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("/usr/bin/plutil is not readable on this host")
        }
        let snapshot = try AnalysisEngine().analyze(url: url)
        XCTAssertEqual(Set(snapshot.objcClasses.map(\.name)),
                       ["PLUMutableArray", "PLUMutableDictionary", "PLUContext"])
        let header = DocumentExportService().renderObjectiveCHeader(snapshot: snapshot)
        XCTAssertTrue(header.contains("@interface PLUContext : NSObject"), header)
        XCTAssertTrue(header.contains("- (BOOL)execute;"), header)
        XCTAssertTrue(header.contains("@end"), header)
    }

    /// No functions -> empty pseudocode (both scopes), no crash.
    func testRenderPseudocodeEmptyWhenNoFunctions() {
        let snap = snapshot(instructions: [insn(0x1000)])
        XCTAssertEqual(DocumentExportService().renderPseudocode(snapshot: snap, selectedAddress: nil), "")
        XCTAssertEqual(DocumentExportService().renderAllPseudocode(snapshot: snap), "")
    }

    // MARK: - Focused image export

    private func multiImageExportSnapshot() -> WorkspaceSnapshot {
        let secondary = ImageSlot(rawValue: 1)
        var primary = ImageAnalysis()
        primary.instructions = [insn(0x1000, bytes: "1f 20 03 d5", "nop")]
        primary.functions = [function("primary_function", 0x1000, 0x1004)]
        primary.objcClasses = [ObjCClass(
            name: "PrimaryClass", superclassName: "NSObject", adoptedProtocols: [],
            classMethods: [], instanceMethods: [], ivars: [], properties: []
        )]
        primary.swiftTypes = [SwiftTypeDescriptor(kind: .struct, name: "PrimaryType")]
        var sibling = ImageAnalysis()
        sibling.instructions = [insn(0x1000, bytes: "c0 03 5f d6", "ret")]
        sibling.functions = [function("sibling_function", 0x1000, 0x1004)]
        sibling.objcClasses = [ObjCClass(
            name: "SiblingClass", superclassName: "NSObject", adoptedProtocols: [],
            classMethods: [], instanceMethods: [], ivars: [], properties: []
        )]
        sibling.swiftTypes = [SwiftTypeDescriptor(kind: .struct, name: "SiblingType")]
        return WorkspaceSnapshot(
            binaries: [
                BinaryImage(id: UUID(), name: "Primary", path: "/fixtures/primary",
                            kind: "Mach-O", architecture: "arm64", slot: .primary),
                BinaryImage(id: UUID(), name: "Sibling", path: "/fixtures/sibling",
                            kind: "Mach-O", architecture: "arm64", slot: secondary),
            ],
            analysisBySlot: [.primary: primary, secondary: sibling]
        )
    }

    func testListingExportUsesRequestedImageWithOverlappingAddresses() {
        var snap = multiImageExportSnapshot()
        let secondary = ImageSlot(rawValue: 1)
        snap.addressOverrides[.primary(0x1000)] = AddressOverride(customName: "primary_override")
        snap.addressOverrides[ImageAddress(slot: secondary, address: 0x1000)] =
            AddressOverride(customName: "sibling_override", customComment: "sibling evidence")
        let service = DocumentExportService()
        let text = service.renderListing(snapshot: snap, in: secondary)
        XCTAssertTrue(text.contains("sibling_override:"), text)
        XCTAssertTrue(text.contains("sibling evidence"), text)
        XCTAssertTrue(text.contains("ret"), text)
        XCTAssertFalse(text.contains("primary_override"), text)
        XCTAssertFalse(text.contains("nop"), text)
        XCTAssertEqual(service.renderListing(snapshot: snap),
                       service.renderListing(snapshot: snap, in: .primary))
    }

    func testObjectiveCHeaderExportUsesRequestedImage() {
        let snap = multiImageExportSnapshot()
        let service = DocumentExportService()
        let text = service.renderObjectiveCHeader(snapshot: snap, in: ImageSlot(rawValue: 1))
        XCTAssertTrue(text.contains("@interface SiblingClass"), text)
        XCTAssertFalse(text.contains("PrimaryClass"), text)
        XCTAssertEqual(service.renderObjectiveCHeader(snapshot: snap),
                       service.renderObjectiveCHeader(snapshot: snap, in: .primary))
    }

    func testSwiftInterfaceExportUsesRequestedImage() {
        let snap = multiImageExportSnapshot()
        let service = DocumentExportService()
        let text = service.renderSwiftInterface(snapshot: snap, in: ImageSlot(rawValue: 1))
        XCTAssertTrue(text.contains("struct SiblingType"), text)
        XCTAssertFalse(text.contains("PrimaryType"), text)
        XCTAssertEqual(service.renderSwiftInterface(snapshot: snap),
                       service.renderSwiftInterface(snapshot: snap, in: .primary))
    }

}

// Old scans deliberately retained here as the independent equivalence oracle.
private func referenceCodeExclusions(_ snapshot: WorkspaceSnapshot, in slot: ImageSlot) -> Set<UInt64> {
    var result = Set<UInt64>()
    for (key, override) in snapshot.addressOverrides
    where key.slot == slot && (override.isData || override.isUndefined || !(override.dataShape?.isEmpty ?? true)) {
        result.insert(key.address)
    }
    guard let analysis = snapshot.analysis(in: slot), !analysis.codeDataRanges.isEmpty else { return result }
    for row in analysis.instructions where snapshot.isInLoaderDataRange(row.address, in: slot) {
        result.insert(row.address)
    }
    return result
}

private func referencePseudocodeTarget(_ snapshot: WorkspaceSnapshot, selectedAddress: UInt64?,
                                      in slot: ImageSlot) -> (function: FunctionSummary, instructions: [InstructionRow])? {
    let analysis = snapshot.analysis(in: slot)
    let resolved = selectedAddress.flatMap { snapshot.enclosingFunction(for: $0, in: slot) }
        ?? analysis?.functions.first
    guard let function = resolved else { return nil }
    let excluded = referenceCodeExclusions(snapshot, in: slot)
    let body = (analysis?.instructions ?? []).filter { row in
        guard row.address >= function.startAddress, !excluded.contains(row.address) else { return false }
        if function.endAddress > function.startAddress { return row.address < function.endAddress }
        return row.address == function.startAddress
    }
    let symbolizer = BranchTargetSymbolizer(namesByAddress: snapshot.branchTargetNames(
        in: slot, restrictedTo: WorkspaceSnapshot.directCallTargets(in: body)))
    return (function, body.map { symbolizer.symbolized($0, callsOnly: true) })
}

extension DocumentExportServiceTests {
    func testLibjpegIndexedSlicesMatchReferenceAndReportSinglePassTiming() throws {
        let url = URL(fileURLWithPath: "/opt/homebrew/lib/libjpeg.8.dylib")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Named libjpeg witness is absent")
        }
        // I6MergedUpsampleWitnessTests on this main decodes embedded hex with ARM64Decoder;
        // it has no loader/snapshot helper. The existing AnalysisEngine loader uses that
        // same decoder and constructs the whole-image snapshot for the named real binary.
        let snap = try AnalysisEngine().analyze(url: url)
        XCTAssertFalse(snap.functions.isEmpty)
        XCTAssertFalse(snap.instructions.isEmpty)
        let clock = ContinuousClock()
        let referenceStart = clock.now
        let reference = snap.functions.map {
            referencePseudocodeTarget(snap, selectedAddress: $0.startAddress, in: snap.primarySlot)
        }
        let referenceTime = referenceStart.duration(to: clock.now)
        // Includes first index construction; no warmup and no repeated timing pass.
        let indexedStart = clock.now
        let indexed = snap.functions.map { snap.pseudocodeTarget(selectedAddress: $0.startAddress) }
        let indexedTime = indexedStart.duration(to: clock.now)
        print("E4 libjpeg single pass: reference=\(referenceTime) indexed=\(indexedTime) functions=\(snap.functions.count) rows=\(snap.instructions.count) codeDataRanges=\(snap.codeDataRanges.count)")
        XCTAssertEqual(reference.count, indexed.count)
        for (expected, actual) in zip(reference, indexed) {
            XCTAssertEqual(actual?.function, expected?.function)
            XCTAssertEqual(actual?.instructions, expected?.instructions)
        }
        XCTAssertEqual(snap.codeExcludedAddresses(in: snap.primarySlot), referenceCodeExclusions(snap, in: snap.primarySlot))
    }

    func testIndexedSlicesPreserveOrderExclusionsAndSnapshotCopies() throws {
        // Deliberately shuffled, duplicate-address rows plus degenerate/overflow boundaries.
        var snap = snapshot(instructions: [
            insn(0x1008, "nop"), insn(0x2000, "ret"), insn(0x1000, "bl", "0x2000"),
            insn(0x1004, "nop"), insn(0x1008, "ret"), insn(UInt64.max, "ret"),
            insn(0x100C, "ret"),
        ], functions: [function("alpha", 0x1000, 0x1010), function("beta", 0x2000, 0x2004),
                       function("last", UInt64.max, UInt64.max), function("empty", 0x3000, 0x2FFF)])
        snap.codeDataRanges = [
            .init(id: UUID(), address: 0x1004, size: 4, kind: "data"),
            .init(id: UUID(), address: 0x100C, size: 4, kind: "data"),
            .init(id: UUID(), address: UInt64.max, size: 4, kind: "overflow"),
        ]
        func assertEquivalent(_ value: WorkspaceSnapshot) {
            XCTAssertEqual(value.codeExcludedAddresses(in: .primary), referenceCodeExclusions(value, in: .primary))
            for function in value.functions {
                let expected = referencePseudocodeTarget(value, selectedAddress: function.startAddress, in: .primary)
                let actual = value.pseudocodeTarget(selectedAddress: function.startAddress)
                XCTAssertEqual(actual?.function, expected?.function)
                XCTAssertEqual(actual?.instructions, expected?.instructions)
            }
        }
        assertEquivalent(snap)
        let original = snap
        let originalMemo = try XCTUnwrap(original.analysis(in: .primary)).exportInstructionMemo
        let originalBody = original.pseudocodeTarget(selectedAddress: 0x1000)?.instructions
        snap.instructions.append(insn(0x100A, "nop"))
        let mutatedAnalysis = try XCTUnwrap(snap.analysis(in: .primary))
        XCTAssertFalse(mutatedAnalysis.exportInstructionMemo === originalMemo)
        // Read the index directly so the old linear pseudocodeTarget cannot mask stale reuse.
        XCTAssertEqual(mutatedAnalysis.exportInstructionIndex().instructions(start: 0x1000, end: 0x1010),
                       snap.instructions.filter { $0.address >= 0x1000 && $0.address < 0x1010 })
        XCTAssertEqual(snap.pseudocodeTarget(selectedAddress: 0x1000)?.instructions,
                       referencePseudocodeTarget(snap, selectedAddress: 0x1000, in: .primary)?.instructions)
        XCTAssertNotEqual(snap.pseudocodeTarget(selectedAddress: 0x1000)?.instructions, originalBody)
        snap.codeDataRanges = []
        let rangeMutatedAnalysis = try XCTUnwrap(snap.analysis(in: .primary))
        XCTAssertFalse(rangeMutatedAnalysis.exportInstructionMemo === mutatedAnalysis.exportInstructionMemo)
        XCTAssertEqual(rangeMutatedAnalysis.exportInstructionIndex().loaderExcludedAddresses,
                       referenceCodeExclusions(snap, in: .primary))
        XCTAssertEqual(snap.pseudocodeTarget(selectedAddress: 0x1000)?.instructions,
                       referencePseudocodeTarget(snap, selectedAddress: 0x1000, in: .primary)?.instructions)
        snap.addressOverrides[.primary(0x1008)] = AddressOverride(isUndefined: true)
        assertEquivalent(snap)
        assertEquivalent(original)
    }

    func testWholeImageTextEqualsReferenceScans() throws {
        // Reuse the existing two-function export fixture, with/without loader data exclusions.
        let rows = [insn(0x2000, bytes: "00 00 00 00", "udf", "#0", comment: "two"),
                    insn(0x1000, bytes: "00 00 00 00", "udf", "#0", comment: "one"),
                    insn(0x1004, "nop"), insn(0x1008, "ret")]
        var snap = snapshot(instructions: rows, functions: [
            function("_beta", 0x2000, 0x2004), function("_alpha", 0x1000, 0x100C)])
        for withData in [false, true] {
            if withData { snap.codeDataRanges = [.init(id: UUID(), address: 0x1004, size: 4, kind: "data")] }
            let expected = snap.functions.sorted { $0.startAddress < $1.startAddress }.compactMap { function -> String? in
                guard let target = referencePseudocodeTarget(snap, selectedAddress: function.startAddress, in: .primary),
                      target.function.startAddress == function.startAddress else { return nil }
                // Only the two slicing results are replaced; all printer inputs retain the
                // same snapshot authority. This fixture has no indirect calls.
                var input = snap.pseudocodeRenderInput(selectedAddress: function.startAddress, in: .primary)
                input.instructions = target.instructions
                return DocumentExportService().pseudocodeText(for: input)
            }.joined(separator: "\n\n")
            XCTAssertEqual(Data(DocumentExportService().renderAllPseudocode(snapshot: snap).utf8), Data(expected.utf8))
        }
    }
}
