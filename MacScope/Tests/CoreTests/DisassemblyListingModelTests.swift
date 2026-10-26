import XCTest
@testable import MacScope

/// Tier 2 — additive listing rows: section/segment group headers, standalone label
/// rows at function starts / named addresses, and inline-vs-prefix comment placement.
///
/// These exercise the pure `DisassemblyListingBuilder` (no SwiftUI). The builder
/// interleaves synthetic rows around the pre-existing instruction rows; the existing
/// instruction rows must survive verbatim and in order.
final class DisassemblyListingModelTests: XCTestCase {

    func testSelectionScrollTargetRequiresFocusedImageAndExistingInstruction() {
        let target = ImageAddress(slot: .primary, address: 0x1000)
        XCTAssertEqual(DisassemblyScrollAnchor.selectionTarget(target, focusedSlot: .primary,
            containsInstruction: { $0 == 0x1000 }), target)
        XCTAssertNil(DisassemblyScrollAnchor.selectionTarget(target,
            focusedSlot: ImageSlot(rawValue: 1), containsInstruction: { _ in true }))
        XCTAssertNil(DisassemblyScrollAnchor.selectionTarget(target, focusedSlot: .primary,
            containsInstruction: { _ in false }))
        XCTAssertNil(DisassemblyScrollAnchor.selectionTarget(nil, focusedSlot: .primary,
            containsInstruction: { _ in true }))
        XCTAssertNotEqual(DisassemblyScrollAnchor.instruction(target),
            DisassemblyScrollAnchor.instruction(ImageAddress(slot: ImageSlot(rawValue: 1), address: 0x1000)))
    }

    private func insn(
        _ address: UInt64,
        _ mnemonic: String = "nop",
        _ operands: String = "",
        comment: String? = nil
    ) -> InstructionRow {
        InstructionRow(address: address, bytes: "", mnemonic: mnemonic, operands: operands,
                       hasBreakpoint: false, comment: comment)
    }

    private func snapshot(
        instructions: [InstructionRow],
        functions: [FunctionSummary] = [],
        symbols: [SymbolSummary] = [],
        sections: [SectionSummary] = [],
        overrides: [ImageAddress: AddressOverride] = [:]
    ) -> WorkspaceSnapshot {
        var snap = WorkspaceSnapshot(binaries: [], functions: functions,
                                     instructions: instructions, xrefs: [], hexBytes: Data())
        snap.symbols = symbols
        snap.sections = sections
        snap.addressOverrides = overrides
        return snap
    }

    private func section(_ name: String, _ address: UInt64, executable: Bool = true) -> SectionSummary {
        SectionSummary(id: UUID(), name: name, address: address, size: 0x100,
                       fileOffset: 0, isExecutable: executable)
    }

    private func function(_ name: String, _ start: UInt64, _ end: UInt64) -> FunctionSummary {
        FunctionSummary(id: UUID(), name: name, startAddress: start, endAddress: end, confidence: 1)
    }

    private func symbol(_ name: String, _ address: UInt64) -> SymbolSummary {
        SymbolSummary(id: UUID(), name: name, address: address, kind: "function", libraryName: nil)
    }

    // MARK: - Focused-image rendering (Phase 4.2)

    func testBuildRendersFocusedSlotInstructionsNotPrimary() {
        let s1 = ImageSlot(rawValue: 1)
        var a = ImageAnalysis()
        a.instructions = [insn(0x1000)]
        a.functions = [function("a", 0x1000, 0x1004)]
        var b = ImageAnalysis()
        b.instructions = [insn(0x2000)]
        b.functions = [function("b", 0x2000, 0x2004)]
        let bin0 = BinaryImage(id: UUID(), name: "i0", path: "/tmp/i0", kind: "exe", architecture: "arm64", slot: .primary)
        let bin1 = BinaryImage(id: UUID(), name: "i1", path: "/tmp/i1", kind: "exe", architecture: "arm64", slot: s1)
        let snap = WorkspaceSnapshot(binaries: [bin0, bin1], analysisBySlot: [.primary: a, s1: b])

        let primaryRows = DisassemblyListingBuilder.build(snapshot: snap)
        XCTAssertTrue(primaryRows.contains { $0.instruction?.address == 0x1000 })
        XCTAssertFalse(primaryRows.contains { $0.instruction?.address == 0x2000 })

        let focusedRows = DisassemblyListingBuilder.build(snapshot: snap, slot: s1)
        XCTAssertTrue(focusedRows.contains { $0.instruction?.address == 0x2000 })
        XCTAssertFalse(focusedRows.contains { $0.instruction?.address == 0x1000 })
    }

    // MARK: - Section header rows

    func testSectionHeaderAppearsAtBoundary() {
        let snap = snapshot(
            instructions: [insn(0x1000), insn(0x1004), insn(0x2000)],
            sections: [section("__TEXT,__text", 0x1000), section("__TEXT,__stubs", 0x2000)]
        )
        let rows = DisassemblyListingBuilder.build(snapshot: snap)

        // The first row must be the __text header (boundary at 0x1000).
        guard case let .sectionHeader(first) = rows.first else {
            return XCTFail("expected a section header as the first row, got \(String(describing: rows.first))")
        }
        XCTAssertEqual(first.name, "__TEXT,__text")
        XCTAssertEqual(first.address, 0x1000)
        XCTAssertTrue(first.isExecutable)

        // The second header must appear immediately before the 0x2000 instruction.
        let headerNames = rows.compactMap { row -> String? in
            if case let .sectionHeader(h) = row { return h.name }
            return nil
        }
        XCTAssertEqual(headerNames, ["__TEXT,__text", "__TEXT,__stubs"])

        // The __stubs header must sit directly before the 0x2000 instruction row.
        let index2000 = rows.firstIndex { $0.instruction?.address == 0x2000 }
        XCTAssertNotNil(index2000)
        if let index2000 {
            guard case let .sectionHeader(h) = rows[index2000 - 1] else {
                return XCTFail("expected __stubs header just before 0x2000")
            }
            XCTAssertEqual(h.name, "__TEXT,__stubs")
        }
    }

    func testSectionStartingBeforeFirstInstructionStillEmitsHeaderOnce() {
        // Section starts at 0x0F00 but the first instruction is 0x1000; the header
        // should still fire exactly once, at the first instruction at/after it.
        let snap = snapshot(
            instructions: [insn(0x1000), insn(0x1004)],
            sections: [section("__TEXT,__text", 0x0F00)]
        )
        let rows = DisassemblyListingBuilder.build(snapshot: snap)
        let headerCount = rows.filter { if case .sectionHeader = $0 { return true }; return false }.count
        XCTAssertEqual(headerCount, 1)
        if case let .sectionHeader(h) = rows.first {
            XCTAssertEqual(h.address, 0x0F00)
        } else {
            XCTFail("expected the header first")
        }
    }

    func testNonExecutableSectionFlagPropagates() {
        let snap = snapshot(
            instructions: [insn(0x4000)],
            sections: [section("__DATA,__data", 0x4000, executable: false)]
        )
        let rows = DisassemblyListingBuilder.build(snapshot: snap)
        guard case let .sectionHeader(h) = rows.first else {
            return XCTFail("expected a section header")
        }
        XCTAssertFalse(h.isExecutable)
    }

    // MARK: - Label rows

    func testLabelRowAppearsAtFunctionStart() {
        let snap = snapshot(
            instructions: [insn(0x1000), insn(0x1004), insn(0x1008)],
            functions: [function("_main", 0x1000, 0x100C)]
        )
        let rows = DisassemblyListingBuilder.build(snapshot: snap)

        // A label row must immediately precede the function's first instruction.
        let firstInsnIndex = rows.firstIndex { $0.instruction?.address == 0x1000 }
        XCTAssertNotNil(firstInsnIndex)
        if let firstInsnIndex {
            guard case let .label(label) = rows[firstInsnIndex - 1] else {
                return XCTFail("expected a label row just before the function start")
            }
            XCTAssertEqual(label.name, "_main")
            XCTAssertEqual(label.address, 0x1000)
            XCTAssertTrue(label.isFunctionStart)
        }
    }

    func testLabelRowUsesUserRenameOverFunctionName() {
        let snap = snapshot(
            instructions: [insn(0x1000)],
            functions: [function("sub_1000", 0x1000, 0x1004)],
            overrides: [.primary(0x1000): AddressOverride(customName: "parseHeader")]
        )
        let rows = DisassemblyListingBuilder.build(snapshot: snap)
        let labelNames = rows.compactMap { row -> String? in
            if case let .label(l) = row { return l.name }
            return nil
        }
        XCTAssertEqual(labelNames, ["parseHeader"])
    }

    func testLabelRowAtNamedSymbolThatIsNotAFunction() {
        let snap = snapshot(
            instructions: [insn(0x1000), insn(0x2000)],
            symbols: [symbol("g_table", 0x2000)]
        )
        let rows = DisassemblyListingBuilder.build(snapshot: snap)
        let index2000 = rows.firstIndex { $0.instruction?.address == 0x2000 }
        XCTAssertNotNil(index2000)
        if let index2000 {
            guard case let .label(label) = rows[index2000 - 1] else {
                return XCTFail("expected a label row before the named symbol address")
            }
            XCTAssertEqual(label.name, "g_table")
            XCTAssertFalse(label.isFunctionStart, "a bare symbol is not a function start")
        }
    }

    func testFunctionLabelTakesPrecedenceOverSymbolAtSameAddress() {
        let snap = snapshot(
            instructions: [insn(0x1000)],
            functions: [function("_main", 0x1000, 0x1004)],
            symbols: [symbol("_alias", 0x1000)]
        )
        let rows = DisassemblyListingBuilder.build(snapshot: snap)
        let labels = rows.compactMap { row -> LabelRow? in
            if case let .label(l) = row { return l }
            return nil
        }
        XCTAssertEqual(labels.count, 1)
        XCTAssertEqual(labels.first?.name, "_main")
        XCTAssertEqual(labels.first?.isFunctionStart, true)
    }

    // MARK: - Comment placement (inline vs prefix)

    func testShortCommentIsInlineNotAPrefixRow() {
        let snap = snapshot(instructions: [insn(0x1000, comment: "loop start")])
        let (rows, resolved) = DisassemblyListingBuilder.buildResolved(snapshot: snap)

        let hasPrefixRow = rows.contains { if case .prefixComment = $0 { return true }; return false }
        XCTAssertFalse(hasPrefixRow, "a short comment should stay inline, not become an own-line row")
        XCTAssertEqual(resolved[0x1000]?.inlineComment, "loop start")
    }

    func testMultilineCommentBecomesAPrefixRow() {
        let snap = snapshot(instructions: [insn(0x1000, comment: "first line\nsecond line")])
        let (rows, resolved) = DisassemblyListingBuilder.buildResolved(snapshot: snap)

        // A prefix comment row must appear immediately before the instruction.
        let insnIndex = rows.firstIndex { $0.instruction?.address == 0x1000 }
        XCTAssertNotNil(insnIndex)
        if let insnIndex {
            guard case let .prefixComment(c) = rows[insnIndex - 1] else {
                return XCTFail("expected an own-line prefix comment before the instruction")
            }
            XCTAssertEqual(c.text, "first line\nsecond line")
            XCTAssertEqual(c.address, 0x1000)
        }
        // And the instruction's inline slot must be empty (the comment moved up).
        XCTAssertNil(resolved[0x1000]?.inlineComment)
    }

    func testLongSingleLineCommentBecomesAPrefixRow() {
        let long = String(repeating: "x", count: ListingCommentPlacement.inlineLengthThreshold + 1)
        XCTAssertEqual(ListingCommentPlacement.derivedDefault(forComment: long), .prefix)

        let short = String(repeating: "x", count: ListingCommentPlacement.inlineLengthThreshold)
        XCTAssertEqual(ListingCommentPlacement.derivedDefault(forComment: short), .inline)
    }

    func testUserCommentOverridesDecoderCommentInline() {
        let snap = snapshot(
            instructions: [insn(0x1000, comment: "decoder note")],
            overrides: [.primary(0x1000): AddressOverride(customComment: "user note")]
        )
        let (_, resolved) = DisassemblyListingBuilder.buildResolved(snapshot: snap)
        XCTAssertEqual(resolved[0x1000]?.inlineComment, "user note")
    }

    func testDataMarkedRowSuppressesDecoderCommentButKeepsUserComment() {
        let snap = snapshot(
            instructions: [insn(0x1000, comment: "decoder code note")],
            overrides: [.primary(0x1000): AddressOverride(customComment: "ptr table", isData: true)]
        )
        let (_, resolved) = DisassemblyListingBuilder.buildResolved(snapshot: snap)
        XCTAssertEqual(resolved[0x1000]?.inlineComment, "ptr table")
        XCTAssertTrue(resolved[0x1000]?.isData ?? false)
    }

    func testDataMarkedRowWithNoUserCommentDropsDecoderComment() {
        let snap = snapshot(
            instructions: [insn(0x1000, comment: "decoder code note")],
            overrides: [.primary(0x1000): AddressOverride(isData: true)]
        )
        let (rows, resolved) = DisassemblyListingBuilder.buildResolved(snapshot: snap)
        XCTAssertNil(resolved[0x1000]?.inlineComment)
        let hasPrefix = rows.contains { if case .prefixComment = $0 { return true }; return false }
        XCTAssertFalse(hasPrefix)
    }

    // MARK: - Data shapes (Make Array / Make Alignment / Make String)

    func testArrayShapeRowIsDataAndRendersArrayDirective() {
        let snap = snapshot(
            instructions: [insn(0x1000)],
            overrides: [.primary(0x1000): AddressOverride(dataShape: DataShapeOverride(kind: .array, elementType: "int32_t", elementCount: 16))]
        )
        let (_, resolved) = DisassemblyListingBuilder.buildResolved(snapshot: snap)
        XCTAssertTrue(resolved[0x1000]?.isData ?? false)
        XCTAssertEqual(resolved[0x1000]?.dataShape?.kind, .array)
        XCTAssertEqual(resolved[0x1000]?.shapeDirective?.mnemonic, ".array")
        XCTAssertEqual(resolved[0x1000]?.shapeDirective?.operands, "int32_t[16]")
    }

    func testArrayShapeWithDisplayFormatMaterializesElementValuesInListing() {
        // 4 × int32_t with a hex per-element format, over bytes [1, 2, 0x100, 0xff]
        // (little-endian 4-byte words). The directive carries each element's value.
        var snap = snapshot(
            instructions: [insn(0x1000)],
            sections: [SectionSummary(id: UUID(), name: "__DATA,__data", address: 0x1000,
                                      size: 16, fileOffset: 0, isExecutable: false)],
            overrides: [.primary(0x1000): AddressOverride(dataShape: DataShapeOverride(
                kind: .array, elementType: "int32_t", elementCount: 4, elementDisplayFormat: .hex))]
        )
        snap.imageBytes = Data([
            0x01, 0x00, 0x00, 0x00, // 1
            0x02, 0x00, 0x00, 0x00, // 2
            0x00, 0x01, 0x00, 0x00, // 0x100
            0xFF, 0x00, 0x00, 0x00, // 0xff
        ])
        let (_, resolved) = DisassemblyListingBuilder.buildResolved(snapshot: snap)
        XCTAssertEqual(resolved[0x1000]?.shapeDirective?.mnemonic, ".array")
        XCTAssertEqual(resolved[0x1000]?.shapeDirective?.operands, "int32_t[4] { 0x1, 0x2, 0x100, 0xff }")
    }

    func testArrayShapeWithoutDisplayFormatRendersSignatureOnly() {
        // No per-element format -> the legacy bare type signature (no value braces).
        var snap = snapshot(
            instructions: [insn(0x1000)],
            sections: [SectionSummary(id: UUID(), name: "__DATA,__data", address: 0x1000,
                                      size: 16, fileOffset: 0, isExecutable: false)],
            overrides: [.primary(0x1000): AddressOverride(dataShape: DataShapeOverride(
                kind: .array, elementType: "int32_t", elementCount: 4))]
        )
        snap.imageBytes = Data(repeating: 0, count: 16)
        let (_, resolved) = DisassemblyListingBuilder.buildResolved(snapshot: snap)
        XCTAssertEqual(resolved[0x1000]?.shapeDirective?.operands, "int32_t[4]")
    }

    func testArrayShapeSignedElementRendersNegativeUnderSignedFormats() {
        // int8_t element 0xFF = -1: signed decimal renders -1, hex renders the unsigned
        // byte magnitude 0xff (hex is a bit-pattern view), negativeHex renders -0x1.
        var snap = snapshot(
            instructions: [insn(0x2000)],
            sections: [SectionSummary(id: UUID(), name: "__DATA,__data", address: 0x2000,
                                      size: 4, fileOffset: 0, isExecutable: false)],
            overrides: [.primary(0x2000): AddressOverride(dataShape: DataShapeOverride(
                kind: .array, elementType: "int8_t", elementCount: 2, elementDisplayFormat: .decimal))]
        )
        snap.imageBytes = Data([0xFF, 0x7F]) // -1, 127
        let (_, resolved) = DisassemblyListingBuilder.buildResolved(snapshot: snap)
        XCTAssertEqual(resolved[0x2000]?.shapeDirective?.operands, "int8_t[2] { -1, 127 }")
    }

    func testArrayShapeUnreadableBytesFallBackToSignatureNotWrongValues() {
        // No section/image bytes -> the array directive degrades to the bare signature
        // rather than rendering fabricated element values.
        let snap = snapshot(
            instructions: [insn(0x9000)],
            overrides: [.primary(0x9000): AddressOverride(dataShape: DataShapeOverride(
                kind: .array, elementType: "int32_t", elementCount: 4, elementDisplayFormat: .hex))]
        )
        let (_, resolved) = DisassemblyListingBuilder.buildResolved(snapshot: snap)
        XCTAssertEqual(resolved[0x9000]?.shapeDirective?.operands, "int32_t[4]")
    }

    func testAlignmentShapeRendersBalignDirective() {
        let snap = snapshot(
            instructions: [insn(0x1004)],
            overrides: [.primary(0x1004): AddressOverride(dataShape: DataShapeOverride(kind: .alignment, alignment: 8))]
        )
        let (_, resolved) = DisassemblyListingBuilder.buildResolved(snapshot: snap)
        XCTAssertEqual(resolved[0x1004]?.shapeDirective?.mnemonic, ".balign")
        // 0x1004 is 4 past an 8-boundary -> pads 4.
        XCTAssertEqual(resolved[0x1004]?.shapeDirective?.operands, "8  ; pad 4")
    }

    func testNullTerminatedStringShapeReadsBytesAndRendersAsciz() {
        // Build a snapshot whose section table maps 0x1000 to bytes "Hi\0".
        var snap = snapshot(
            instructions: [insn(0x1000)],
            sections: [SectionSummary(id: UUID(), name: "__TEXT,__cstring", address: 0x1000,
                                      size: 4, fileOffset: 0, isExecutable: false)],
            overrides: [.primary(0x1000): AddressOverride(dataShape: DataShapeOverride(kind: .string, isNullTerminated: true))]
        )
        snap.imageBytes = Data([0x48, 0x69, 0x00, 0x00]) // "Hi\0\0"
        let (_, resolved) = DisassemblyListingBuilder.buildResolved(snapshot: snap)
        XCTAssertEqual(resolved[0x1000]?.shapeDirective?.mnemonic, ".asciz")
        XCTAssertEqual(resolved[0x1000]?.shapeDirective?.operands, "\"Hi\"")
    }

    func testStringShapeWithUnreadableBytesRendersPlaceholderNotMisleadingLiteral() {
        // No section/image bytes -> the reader returns nil; the directive degrades to a
        // placeholder rather than rendering a truncated/wrong literal.
        let snap = snapshot(
            instructions: [insn(0x9000)],
            overrides: [.primary(0x9000): AddressOverride(dataShape: DataShapeOverride(kind: .string, isNullTerminated: false, stringLength: 8))]
        )
        let (_, resolved) = DisassemblyListingBuilder.buildResolved(snapshot: snap)
        XCTAssertEqual(resolved[0x9000]?.shapeDirective?.mnemonic, ".ascii")
        XCTAssertEqual(resolved[0x9000]?.shapeDirective?.operands, "\"?\"")
    }

    func testDataShapeDirectiveEscapesControlAndQuoteBytes() {
        // Hardening: a quote/backslash/newline in the bytes must be C-escaped so the
        // emitted literal stays well-formed.
        let shape = DataShapeOverride(kind: .string, isNullTerminated: false, stringLength: 5)
        let bytes = Data([0x22, 0x5C, 0x0A, 0x09, 0x01]) // " \ \n \t 0x01
        let text = WorkspaceSnapshot.readCString(at: 0, shape: shape) { _, count in bytes.prefix(count) }
        XCTAssertEqual(text, "\\\"\\\\\\n\\t\\x01")
    }

    // MARK: - v22: Mark-as-Undefined render + patch flag

    func testUndefinedRowRendersByteUndefinedDirectiveAndSuppressesComment() {
        let row = InstructionRow(address: 0x1000, bytes: "ff 83 00 d1", mnemonic: "sub",
                                 operands: "sp, sp, #0x20", hasBreakpoint: false, comment: "decoder note")
        let snap = snapshot(
            instructions: [row],
            overrides: [.primary(0x1000): AddressOverride(isUndefined: true)]
        )
        let (_, resolved) = DisassemblyListingBuilder.buildResolved(snapshot: snap)
        let resolvedRow = resolved[0x1000]
        XCTAssertTrue(resolvedRow?.isUndefined ?? false)
        XCTAssertEqual(resolvedRow?.undefinedDirective?.mnemonic, ".long")
        // The four raw bytes render as a little-endian word annotated "undefined".
        XCTAssertEqual(resolvedRow?.undefinedDirective?.operands, "0xd10083ff  ; undefined")
        // The decoder comment is suppressed for an undefined row.
        XCTAssertNil(resolvedRow?.inlineComment)
    }

    func testUndefinedRowKeepsUserComment() {
        let row = InstructionRow(address: 0x1000, bytes: "ff 83 00 d1", mnemonic: "sub",
                                 operands: "", hasBreakpoint: false, comment: "decoder note")
        let snap = snapshot(
            instructions: [row],
            overrides: [.primary(0x1000): AddressOverride(customComment: "raw padding", isUndefined: true)]
        )
        let (_, resolved) = DisassemblyListingBuilder.buildResolved(snapshot: snap)
        XCTAssertEqual(resolved[0x1000]?.inlineComment, "raw padding")
    }

    func testPatchedRowIsFlagged() {
        let row = InstructionRow(address: 0x1000, bytes: "1f 20 03 d5", mnemonic: "nop",
                                 operands: "", hasBreakpoint: false, comment: nil)
        let snap = snapshot(
            instructions: [row],
            overrides: [.primary(0x1000): AddressOverride(patch: BytePatch.arm64NOP)]
        )
        let (_, resolved) = DisassemblyListingBuilder.buildResolved(snapshot: snap)
        XCTAssertTrue(resolved[0x1000]?.isPatched ?? false)
    }

    // MARK: - Additive invariant: existing instruction rows are preserved

    func testInstructionRowsArePreservedInOrder() {
        let originals = [insn(0x1000, "mov"), insn(0x1004, "add"), insn(0x1008, "ret")]
        let snap = snapshot(
            instructions: originals,
            functions: [function("_main", 0x1000, 0x100C)],
            sections: [section("__TEXT,__text", 0x1000)]
        )
        let rows = DisassemblyListingBuilder.build(snapshot: snap)
        let extracted = rows.compactMap(\.instruction)
        XCTAssertEqual(extracted, originals, "all instruction rows must survive verbatim and in order")
    }

    func testEmptyInstructionsProduceNoRows() {
        let snap = snapshot(instructions: [],
                            sections: [section("__TEXT,__text", 0x1000)],
                            overrides: [:])
        XCTAssertTrue(DisassemblyListingBuilder.build(snapshot: snap).isEmpty)
    }

    func testRowIdentitiesAreUnique() {
        let snap = snapshot(
            instructions: [insn(0x1000), insn(0x1004, comment: "multi\nline")],
            functions: [function("_main", 0x1000, 0x1008)],
            sections: [section("__TEXT,__text", 0x1000)]
        )
        let rows = DisassemblyListingBuilder.build(snapshot: snap)
        let ids = rows.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "row ids must be unique for ForEach")
    }

    // MARK: - Live-PC row flag

    func testLiveProgramCounterFlagsExactlyTheMatchingRow() {
        let snap = snapshot(instructions: [insn(0x1000), insn(0x1004), insn(0x1008)])
        let listing = DisassemblyListingBuilder.buildResolved(
            snapshot: snap,
            liveProgramCounter: 0x1004
        )

        XCTAssertEqual(listing.resolved[0x1004]?.isLiveProgramCounter, true,
                       "the PC-address row must be the live-PC row")
        XCTAssertEqual(listing.resolved[0x1000]?.isLiveProgramCounter, false)
        XCTAssertEqual(listing.resolved[0x1008]?.isLiveProgramCounter, false)

        let flagged = listing.resolved.values.filter(\.isLiveProgramCounter)
        XCTAssertEqual(flagged.count, 1, "exactly one row may be the live-PC row")
    }

    func testLiveProgramCounterNilFlagsNoRow() {
        let snap = snapshot(instructions: [insn(0x1000), insn(0x1004)])
        let listing = DisassemblyListingBuilder.buildResolved(
            snapshot: snap,
            liveProgramCounter: nil
        )

        XCTAssertTrue(
            listing.resolved.values.allSatisfy { !$0.isLiveProgramCounter },
            "a nil PC must clear the live-PC highlight from every row"
        )
    }

    func testLiveProgramCounterDefaultParameterIsNoHighlight() {
        // The default (no PC argument) leaves every row unflagged — callers that do
        // not pass a PC are unaffected.
        let snap = snapshot(instructions: [insn(0x1000), insn(0x1004)])
        let listing = DisassemblyListingBuilder.buildResolved(snapshot: snap)
        XCTAssertTrue(listing.resolved.values.allSatisfy { !$0.isLiveProgramCounter })
    }

    func testLiveProgramCounterOutsideListingFlagsNoRow() {
        let snap = snapshot(instructions: [insn(0x1000), insn(0x1004)])
        // PC sits at an address that is not present in this listing.
        let listing = DisassemblyListingBuilder.buildResolved(
            snapshot: snap,
            liveProgramCounter: 0x2000
        )
        XCTAssertTrue(listing.resolved.values.allSatisfy { !$0.isLiveProgramCounter })
        XCTAssertNil(
            DisassemblyListingBuilder.liveProgramCounterRowAddress(snapshot: snap, programCounter: 0x2000),
            "a PC outside the listing maps to no row"
        )
    }

    func testLiveProgramCounterRowAddressPureMapping() {
        let snap = snapshot(instructions: [insn(0x1000), insn(0x1004), insn(0x1008)])
        XCTAssertEqual(
            DisassemblyListingBuilder.liveProgramCounterRowAddress(snapshot: snap, programCounter: 0x1008),
            0x1008
        )
        XCTAssertNil(
            DisassemblyListingBuilder.liveProgramCounterRowAddress(snapshot: snap, programCounter: nil)
        )
        // A PC landing mid-instruction (not on an instruction boundary) flags no row.
        XCTAssertNil(
            DisassemblyListingBuilder.liveProgramCounterRowAddress(snapshot: snap, programCounter: 0x1006)
        )
    }
}
