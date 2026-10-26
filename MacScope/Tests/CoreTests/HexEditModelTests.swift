import AppKit
import XCTest
@testable import MacScope

/// Tests for in-pane hex editing. The hex pane is a pure AppKit `NSTextView`, so per the track
/// guidance these exercise the MODEL/BRIDGE layer (`HexEditModel`, the `WorkspaceStore` edit
/// seam, and the geometry the AppKit caret relies on) — NOT pixels. A typed byte must become the
/// correct `BytePatch` at the correct virtual address, be undoable, and reject invalid input.
@MainActor
final class HexEditModelTests: XCTestCase {

    // MARK: - Offset ↔ address mapping

    func testAddressForOffsetUsesLinearAnchoring() {
        let model = HexEditModel(bytes: Data([0xaa, 0xbb, 0xcc, 0xdd]), baseAddress: 0x1_0000_0000)
        XCTAssertEqual(model.address(forOffset: 0), 0x1_0000_0000)
        XCTAssertEqual(model.address(forOffset: 3), 0x1_0000_0003)
        // Out of window / negative → nil (never traps).
        XCTAssertNil(model.address(forOffset: 4))
        XCTAssertNil(model.address(forOffset: -1))
    }

    func testAddressMappingIsOverflowSafeAtTopOfAddressSpace() {
        let model = HexEditModel(bytes: Data([0x00, 0x01]), baseAddress: UInt64.max)
        XCTAssertEqual(model.address(forOffset: 0), UInt64.max)
        // offset 1 would overflow — must be nil, not a trap or a wrap to 0.
        XCTAssertNil(model.address(forOffset: 1))
    }

    func testNoBaseAddressIsReadOnly() {
        let model = HexEditModel(bytes: Data([0xaa]), baseAddress: nil)
        XCTAssertTrue(model.isReadOnly)
        XCTAssertEqual(model.resolveEdit(offset: 0, hexByte: "4f"), .readOnly)
        XCTAssertNil(model.address(forOffset: 0))
    }

    func testEmptyWindowIsReadOnly() {
        let model = HexEditModel(bytes: Data(), baseAddress: 0x1000)
        XCTAssertTrue(model.isReadOnly)
        XCTAssertEqual(model.resolveEdit(offset: 0, hexByte: "4f"), .readOnly)
    }

    // MARK: - Full-byte edits + validation

    func testResolveEditAcceptsTwoHexDigits() {
        let model = HexEditModel(bytes: Data([0x00, 0x11]), baseAddress: 0x4000)
        XCTAssertEqual(model.resolveEdit(offset: 1, hexByte: "9c"), .patch(address: 0x4001, byte: 0x9c))
        // Case-insensitive, whitespace-tolerant.
        XCTAssertEqual(model.resolveEdit(offset: 0, hexByte: " AB "), .patch(address: 0x4000, byte: 0xab))
    }

    func testResolveEditRejectsInvalidHex() {
        let model = HexEditModel(bytes: Data([0x00, 0x11]), baseAddress: 0x4000)
        XCTAssertEqual(model.resolveEdit(offset: 0, hexByte: "zz"), .invalidInput)   // non-hex
        XCTAssertEqual(model.resolveEdit(offset: 0, hexByte: "4"), .invalidInput)    // one digit
        XCTAssertEqual(model.resolveEdit(offset: 0, hexByte: "4ff"), .invalidInput)  // three digits
        XCTAssertEqual(model.resolveEdit(offset: 0, hexByte: ""), .invalidInput)     // empty
    }

    func testResolveEditRejectsOutOfRangeOffset() {
        let model = HexEditModel(bytes: Data([0x00]), baseAddress: 0x4000)
        XCTAssertEqual(model.resolveEdit(offset: 5, hexByte: "ff"), .outOfRange)
    }

    // MARK: - Per-keystroke nibble composition

    func testNibbleEditComposesHighThenLow() {
        let model = HexEditModel(bytes: Data([0xab]), baseAddress: 0x8000)
        // Type '3' into the high nibble of 0xab → 0x3b.
        XCTAssertEqual(model.resolveNibbleEdit(offset: 0, nibble: "3", position: .high),
                       .patch(address: 0x8000, byte: 0x3b))
        // Type 'c' into the low nibble of 0xab → 0xac.
        XCTAssertEqual(model.resolveNibbleEdit(offset: 0, nibble: "c", position: .low),
                       .patch(address: 0x8000, byte: 0xac))
    }

    func testNibbleEditRejectsNonHexDigit() {
        let model = HexEditModel(bytes: Data([0xab]), baseAddress: 0x8000)
        XCTAssertEqual(model.resolveNibbleEdit(offset: 0, nibble: "g", position: .high), .invalidInput)
    }

    // MARK: - Caret navigation

    func testCaretMovesWithinWindowAndClampsAtEdges() {
        // 3 rows of 16 + 4 = 36 bytes.
        let model = HexEditModel(bytes: Data(count: 36), baseAddress: 0x1000)
        XCTAssertEqual(model.offset(movingFrom: 0, .left, bytesPerRow: 16), 0)   // clamped at start
        XCTAssertEqual(model.offset(movingFrom: 0, .right, bytesPerRow: 16), 1)
        XCTAssertEqual(model.offset(movingFrom: 0, .down, bytesPerRow: 16), 16)  // down one row
        XCTAssertEqual(model.offset(movingFrom: 16, .up, bytesPerRow: 16), 0)    // up one row
        XCTAssertEqual(model.offset(movingFrom: 0, .up, bytesPerRow: 16), 0)     // up blocked on row 0
        XCTAssertEqual(model.offset(movingFrom: 35, .right, bytesPerRow: 16), 35) // clamped at end
        XCTAssertEqual(model.offset(movingFrom: 35, .down, bytesPerRow: 16), 35)  // down blocked (no full row below)
    }

    func testCaretNilOnEmptyWindow() {
        let model = HexEditModel(bytes: Data(), baseAddress: 0x1000)
        XCTAssertNil(model.offset(movingFrom: 0, .right, bytesPerRow: 16))
    }

    // MARK: - Accessibility

    func testAccessibilityLabelDescribesAddressAndValue() {
        let model = HexEditModel(bytes: Data([0x4f]), baseAddress: 0x1_0000_0000)
        XCTAssertEqual(model.accessibilityLabel(forOffset: 0), "Byte at 0x100000000, value 0x4F")
        XCTAssertEqual(model.accessibilityLabel(forOffset: 9), "No byte")
    }

    // MARK: - Rendered geometry (caret-cell mapping the AppKit view relies on)

    func testCharacterRangeForOffsetLandsOnHexDigits() throws {
        // Row 0, col 0 starts right after the "%08X" + two spaces (addressColumns = 10).
        let r0 = try XCTUnwrap(EditableHexTextView.characterRange(forOffset: 0, bytesPerRow: 16))
        XCTAssertEqual(r0.location, HexRowLayout.addressColumns)
        XCTAssertEqual(r0.length, 2)
        // Col 1 is one hex-cell stride (3) further along.
        let r1 = try XCTUnwrap(EditableHexTextView.characterRange(forOffset: 1, bytesPerRow: 16))
        XCTAssertEqual(r1.location, HexRowLayout.addressColumns + HexRowLayout.hexCellStride)
    }

    func testCharacterRangeForOffsetRejectsOverflowingGeometry() {
        XCTAssertNil(
            EditableHexTextView.characterRange(
                forOffset: Int.max,
                bytesPerRow: HexRowLayout.bytesPerRow
            )
        )
        XCTAssertNil(
            EditableHexTextView.characterRange(
                forOffset: 0,
                bytesPerRow: Int.max
            )
        )
    }

    func testByteOffsetForCharacterIndexAcceptsOnlyHexDigits() {
        let firstCell = HexRowLayout.addressColumns
        XCTAssertEqual(
            EditableHexTextView.byteOffset(
                forCharacterIndex: firstCell,
                byteCount: 16,
                bytesPerRow: HexRowLayout.bytesPerRow
            ),
            0
        )
        XCTAssertEqual(
            EditableHexTextView.byteOffset(
                forCharacterIndex: firstCell + 1,
                byteCount: 16,
                bytesPerRow: HexRowLayout.bytesPerRow
            ),
            0
        )
        XCTAssertEqual(
            EditableHexTextView.byteOffset(
                forCharacterIndex: firstCell + HexRowLayout.hexCellStride,
                byteCount: 16,
                bytesPerRow: HexRowLayout.bytesPerRow
            ),
            1
        )

        let hexColumnWidth = HexRowLayout.bytesPerRow * HexRowLayout.hexCellStride - 1
        let asciiStart = HexRowLayout.addressColumns + hexColumnWidth + 2 + 1
        for rejected in [
            0,
            HexRowLayout.addressColumns - 1,
            firstCell + 2,
            HexRowLayout.addressColumns + hexColumnWidth,
            asciiStart - 1,
            asciiStart,
            EditableHexTextView.fullRowWidth(bytesPerRow: HexRowLayout.bytesPerRow) - 1,
        ] {
            XCTAssertNil(
                EditableHexTextView.byteOffset(
                    forCharacterIndex: rejected,
                    byteCount: 16,
                    bytesPerRow: HexRowLayout.bytesPerRow
                ),
                "character index \(rejected) is not a hex digit"
            )
        }
    }

    func testByteOffsetForCharacterIndexMapsLaterRowsAndRejectsPartialPadding() throws {
        let laterRange = try XCTUnwrap(
            EditableHexTextView.characterRange(forOffset: 18, bytesPerRow: HexRowLayout.bytesPerRow)
        )
        XCTAssertEqual(
            EditableHexTextView.byteOffset(
                forCharacterIndex: laterRange.location,
                byteCount: 20,
                bytesPerRow: HexRowLayout.bytesPerRow
            ),
            18
        )
        XCTAssertEqual(
            EditableHexTextView.byteOffset(
                forCharacterIndex: laterRange.location + 1,
                byteCount: 20,
                bytesPerRow: HexRowLayout.bytesPerRow
            ),
            18
        )

        let firstPaddedCell = try XCTUnwrap(
            EditableHexTextView.characterRange(forOffset: 20, bytesPerRow: HexRowLayout.bytesPerRow)
        )
        XCTAssertNil(
            EditableHexTextView.byteOffset(
                forCharacterIndex: firstPaddedCell.location,
                byteCount: 20,
                bytesPerRow: HexRowLayout.bytesPerRow
            )
        )
        XCTAssertNil(
            EditableHexTextView.byteOffset(
                forCharacterIndex: Int.max,
                byteCount: 20,
                bytesPerRow: HexRowLayout.bytesPerRow
            )
        )
        XCTAssertNil(
            EditableHexTextView.byteOffset(forCharacterIndex: -1, byteCount: 20, bytesPerRow: 16)
        )
        XCTAssertNil(
            EditableHexTextView.byteOffset(forCharacterIndex: 10, byteCount: 0, bytesPerRow: 16)
        )
        XCTAssertNil(
            EditableHexTextView.byteOffset(forCharacterIndex: 10, byteCount: 20, bytesPerRow: 0)
        )
    }

    func testRenderLinesMatchesByteCount() {
        let bytes: [UInt8] = Array(0..<20)
        let text = EditableHexTextView.renderLines(bytes: bytes, baseOffset: 0)
        // 20 bytes over 16/row → 2 rows.
        XCTAssertEqual(text.split(separator: "\n").count, 2)
        XCTAssertTrue(text.hasPrefix("00000000  00 01 02"))
    }
}

@MainActor
final class HexTextViewInteractionTests: XCTestCase {
    func testMouseArrowAndPageCaretPublishQualifiedStoreSelectionAndStatus() throws {
        let store = WorkspaceStore(workspaceName: "Hex caret", snapshot: AnalysisEngine.previewSnapshot(),
            engine: AnalysisEngine(), autosaveScheduler: nil)
        let bytes = Array(store.patchedHexWindow().bytes)
        let mappings = store.hexWindowMappings
        let owner = try XCTUnwrap(store.focusedBinary?.id)
        let context = try XCTUnwrap(HexCaretCallbackContext.capture(store: store,
            bytes: Data(bytes), mappings: mappings))
        let fixture = try makeFixture(bytes: bytes, mappings: mappings, editable: true)
        fixture.textView.render(model: HexEditModel(bytes: bytes, mappings: mappings), editable: true,
            selection: store.selectedImageAddress, imageSlot: store.focusedImageSlot, ownerBinaryID: owner)
        var publications: [(Int, ImageAddress)] = []
        fixture.textView.onCaretMove = { offset, target in
            publications.append((offset, target))
            return context.publish(offset: offset, target: target, to: store)
        }
        func assertPublication(_ expectedOffset: Int? = nil) throws {
            let published = try XCTUnwrap(publications.last)
            if let expectedOffset { XCTAssertEqual(published.0, expectedOffset) }
            XCTAssertEqual(published.1, context.target(at: published.0))
            XCTAssertEqual(store.selectedImageAddress, published.1)
            XCTAssertEqual(EditorStatusBar.selectedAddressText(for: store), store.displayAddressString(published.1.address))
            XCTAssertEqual(fixture.textView.selectedRange(),
                EditableHexTextView.characterRange(forOffset: published.0, bytesPerRow: 16))
        }
        XCTAssertGreaterThan(bytes.count, 4)
        try clickByte(offset: 2, in: fixture)
        try assertPublication(2)
        fixture.textView.keyDown(with: try keyEvent(characters: "", keyCode: 124, in: fixture.window))
        try assertPublication(3)
        fixture.textView.keyDown(with: try keyEvent(characters: "", keyCode: 123, in: fixture.window))
        try assertPublication(2)
        fixture.textView.keyDown(with: try keyEvent(characters: "", keyCode: 125, in: fixture.window))
        try assertPublication(18)
        fixture.textView.keyDown(with: try keyEvent(characters: "", keyCode: 126, in: fixture.window))
        try assertPublication(2)
        fixture.textView.keyDown(with: try keyEvent(characters: "", keyCode: 121, in: fixture.window))
        try assertPublication()
        XCTAssertGreaterThan(try XCTUnwrap(publications.last).0, 2)
        let pageDownOffset = try XCTUnwrap(publications.last).0
        fixture.textView.keyDown(with: try keyEvent(characters: "", keyCode: 116, in: fixture.window))
        try assertPublication()
        XCTAssertLessThan(try XCTUnwrap(publications.last).0, pageDownOffset)
        fixture.textView.keyDown(with: try keyEvent(characters: "", keyCode: 119, in: fixture.window))
        try assertPublication(bytes.count - 1)
        fixture.textView.keyDown(with: try keyEvent(characters: "", keyCode: 115, in: fixture.window))
        try assertPublication(0)
        XCTAssertTrue(store.snapshot.addressOverrides.values.allSatisfy { $0.patch == nil })
    }

    func testStoreDrivenSameCaretEchoDoesNotRepublishOrDiscardPartialNibble() throws {
        let fixture = try makeFixture(bytes: Array(0..<32), editable: true)
        let model = HexEditModel(bytes: Array(0..<32), baseAddress: 0x1000)
        let owner = UUID()
        fixture.textView.render(model: model, editable: true, selection: nil, ownerBinaryID: owner)
        var caretTargets: [ImageAddress] = []
        fixture.textView.onCaretMove = { _, target in caretTargets.append(target); return true }
        var edits: [(Int, UInt8)] = []
        fixture.textView.onByteEdit = { offset, value in edits.append((offset, value)); return true }
        try clickByte(offset: 18, in: fixture)
        XCTAssertEqual(caretTargets, [ImageAddress(slot: .primary, address: 0x1012)])
        fixture.textView.keyDown(with: try keyEvent(characters: "A", keyCode: 0, in: fixture.window))
        fixture.textView.render(model: model, editable: true, selection: caretTargets.last, ownerBinaryID: owner)
        XCTAssertEqual(caretTargets.count, 1, "A store echo must not produce another user navigation event")
        XCTAssertTrue(edits.isEmpty)
        fixture.textView.keyDown(with: try keyEvent(characters: "B", keyCode: 11, in: fixture.window))
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.0, 18)
        XCTAssertEqual(edits.first?.1, 0xab)
        XCTAssertEqual(caretTargets.last, ImageAddress(slot: .primary, address: 0x1013))
        XCTAssertEqual(caretTargets.count, 2)
    }

    func testSameSlotOwnerReplacementAbandonsPendingNibble() throws {
        let fixture = try makeFixture(bytes: [0xff], editable: true)
        let model = HexEditModel(bytes: [0xff], baseAddress: 0x1000)
        let selection = ImageAddress(slot: .primary, address: 0x1000)
        fixture.textView.render(model: model, editable: true, selection: selection, ownerBinaryID: UUID())
        var edits: [UInt8] = []
        fixture.textView.onByteEdit = { _, value in edits.append(value); return true }
        fixture.textView.keyDown(with: try keyEvent(characters: "A", keyCode: 0, in: fixture.window))
        fixture.textView.render(model: model, editable: true, selection: selection, ownerBinaryID: UUID())
        fixture.textView.keyDown(with: try keyEvent(characters: "B", keyCode: 11, in: fixture.window))
        XCTAssertTrue(edits.isEmpty)
        fixture.textView.keyDown(with: try keyEvent(characters: "C", keyCode: 8, in: fixture.window))
        XCTAssertEqual(edits, [0xbc])
    }

    func testSameSelectionMappingChangeReprojectsCaretAndAbandonsNibble() throws {
        let fixture = try makeFixture(bytes: [0xff, 0xff], editable: true)
        let owner = UUID()
        let selection = ImageAddress(slot: .primary, address: 0x1000)
        fixture.textView.render(model: HexEditModel(bytes: [0xff, 0xff], baseAddress: 0x1000),
                               editable: true, selection: selection, ownerBinaryID: owner)
        var edits: [(Int, UInt8)] = []
        fixture.textView.onByteEdit = { offset, value in edits.append((offset, value)); return true }
        fixture.textView.keyDown(with: try keyEvent(characters: "A", keyCode: 0, in: fixture.window))
        let remapped = HexEditModel(bytes: [0xff, 0xff], mappings: [
            FileAddressMapping(fileOffset: 1, size: 1, virtualAddress: 0x1000)])
        fixture.textView.render(model: remapped, editable: true, selection: selection, ownerBinaryID: owner)
        XCTAssertEqual(fixture.textView.selectedRange(), EditableHexTextView.characterRange(forOffset: 1, bytesPerRow: 16))
        fixture.textView.keyDown(with: try keyEvent(characters: "B", keyCode: 11, in: fixture.window))
        XCTAssertTrue(edits.isEmpty)
        fixture.textView.keyDown(with: try keyEvent(characters: "C", keyCode: 8, in: fixture.window))
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.0, 1)
        XCTAssertEqual(edits.first?.1, 0xbc)
    }
    func testWorkspaceSelectionMovesCaretAndHighlightsPatchedByte() throws {
        let fixture = try makeFixture(bytes: Array(0..<32), editable: true)
        fixture.textView.render(model: HexEditModel(bytes: Array(0..<32), baseAddress: 0x1000),
            editable: true, selection: ImageAddress(slot: .primary, address: 0x1012),
            imageSlot: .primary, patchedOffsets: [18])
        let range = try XCTUnwrap(EditableHexTextView.characterRange(forOffset: 18, bytesPerRow: 16))
        XCTAssertEqual(fixture.textView.selectedRange(), range)
        XCTAssertNotNil(fixture.textView.textStorage?.attribute(.backgroundColor, at: range.location, effectiveRange: nil))
        var edits: [Int] = []
        fixture.textView.onByteEdit = { offset, _ in edits.append(offset); return true }
        fixture.textView.keyDown(with: try keyEvent(characters: "A", keyCode: 0, in: fixture.window))
        fixture.textView.keyDown(with: try keyEvent(characters: "B", keyCode: 11, in: fixture.window))
        XCTAssertEqual(edits, [18])
    }

    func testEscapeAbandonsPartialByteWithoutCommitting() throws {
        let fixture = try makeFixture(bytes: [0xff], editable: true)
        var edits: [UInt8] = []
        fixture.textView.onByteEdit = { _, value in edits.append(value); return true }
        fixture.textView.keyDown(with: try keyEvent(characters: "1", keyCode: 18, in: fixture.window))
        fixture.textView.keyDown(with: try keyEvent(characters: "", keyCode: 53, in: fixture.window))
        XCTAssertTrue(edits.isEmpty)
        fixture.textView.keyDown(with: try keyEvent(characters: "2", keyCode: 19, in: fixture.window))
        fixture.textView.keyDown(with: try keyEvent(characters: "3", keyCode: 20, in: fixture.window))
        XCTAssertEqual(edits, [0x23])
    }

    func testForeignImageSelectionCannotRetargetKeyboardEditToByteZero() throws {
        let fixture = try makeFixture(bytes: [0xff], editable: true)
        fixture.textView.render(model: HexEditModel(bytes: [0xff], baseAddress: 0x1000), editable: true,
            selection: ImageAddress(slot: ImageSlot(rawValue: 1), address: 0x1000), imageSlot: .primary)
        var editCount = 0
        fixture.textView.onByteEdit = { _, _ in editCount += 1; return true }
        fixture.textView.keyDown(with: try keyEvent(characters: "A", keyCode: 0, in: fixture.window))
        fixture.textView.keyDown(with: try keyEvent(characters: "B", keyCode: 11, in: fixture.window))
        XCTAssertEqual(editCount, 0)
    }
    func testModifiedHexDigitsNeverPatchOrConsumeTheNextNibble() throws {
        for modifiers: NSEvent.ModifierFlags in [.command, .control, .option, [.command, .shift]] {
            let fixture = try makeFixture(bytes: [0xff], editable: true)
            var edits: [UInt8] = []
            fixture.textView.onByteEdit = { _, byte in edits.append(byte); return true }

            fixture.textView.keyDown(with: try keyEvent(
                characters: "1", keyCode: 18, modifiers: modifiers, in: fixture.window
            ))
            XCTAssertTrue(edits.isEmpty, "A modified command key must not become a byte patch: \(modifiers)")

            fixture.textView.keyDown(with: try keyEvent(
                characters: "A", keyCode: 0, modifiers: .shift, in: fixture.window
            ))
            XCTAssertTrue(edits.isEmpty, "An unfinished byte must not create a patch.")
            fixture.textView.keyDown(with: try keyEvent(characters: "F", keyCode: 3, in: fixture.window))
            XCTAssertEqual(edits, [0xaf])
        }
    }

    func testPointHitTestingUsesTextContainerOriginAndRejectsNearestGlyphFallback() throws {
        let fixture = try makeFixture(bytes: Array(0..<20), editable: true)
        let offsetPoint = try point(forByteOffset: 18, in: fixture.textView)
        XCTAssertEqual(fixture.textView.byteOffset(atViewPoint: offsetPoint), 18)

        let offsetRange = try XCTUnwrap(
            EditableHexTextView.characterRange(forOffset: 18, bytesPerRow: HexRowLayout.bytesPerRow)
        )
        let secondDigitPoint = try point(
            forCharacterIndex: offsetRange.location + 1,
            in: fixture.textView
        )
        XCTAssertEqual(fixture.textView.byteOffset(atViewPoint: secondDigitPoint), 18)

        let addressPoint = try point(forCharacterIndex: 0, in: fixture.textView)
        XCTAssertNil(fixture.textView.byteOffset(atViewPoint: addressPoint))

        let firstCell = try XCTUnwrap(
            EditableHexTextView.characterRange(forOffset: 0, bytesPerRow: HexRowLayout.bytesPerRow)
        )
        let separatorPoint = try point(forCharacterIndex: firstCell.location + 2, in: fixture.textView)
        XCTAssertNil(fixture.textView.byteOffset(atViewPoint: separatorPoint))

        let paddedCell = try XCTUnwrap(
            EditableHexTextView.characterRange(forOffset: 20, bytesPerRow: HexRowLayout.bytesPerRow)
        )
        let paddingPoint = try point(forCharacterIndex: paddedCell.location, in: fixture.textView)
        XCTAssertNil(fixture.textView.byteOffset(atViewPoint: paddingPoint))

        let origin = fixture.textView.textContainerOrigin
        XCTAssertNil(
            fixture.textView.byteOffset(
                atViewPoint: NSPoint(x: origin.x / 2, y: origin.y / 2)
            )
        )
        XCTAssertNil(
            fixture.textView.byteOffset(
                atViewPoint: NSPoint(x: fixture.textView.bounds.maxX + 100, y: offsetPoint.y)
            )
        )
        XCTAssertNil(
            fixture.textView.byteOffset(
                atViewPoint: NSPoint(x: offsetPoint.x, y: fixture.textView.bounds.maxY + 100)
            )
        )
    }

    func testEditableClickUpdatesSelectionAccessibilityEditTargetAndArrowOrigin() throws {
        let fixture = try makeFixture(bytes: Array(0..<32), editable: true)
        var edits: [(offset: Int, byte: UInt8)] = []
        fixture.textView.onByteEdit = { offset, byte in
            edits.append((offset, byte))
            return true
        }

        try clickByte(offset: 18, in: fixture)
        XCTAssertTrue(fixture.window.firstResponder === fixture.textView)
        XCTAssertEqual(
            fixture.textView.selectedRange(),
            EditableHexTextView.characterRange(forOffset: 18, bytesPerRow: HexRowLayout.bytesPerRow)
        )
        XCTAssertEqual(
            fixture.textView.accessibilityLabel(),
            "Byte at 0x1012, value 0x12"
        )

        fixture.textView.keyDown(with: try keyEvent(characters: "A", keyCode: 0, in: fixture.window))
        fixture.textView.keyDown(with: try keyEvent(characters: "2", keyCode: 19, in: fixture.window))
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.offset, 18)
        XCTAssertEqual(edits.first?.byte, 0xA2)

        fixture.textView.keyDown(with: try keyEvent(characters: "", keyCode: 123, in: fixture.window))
        fixture.textView.keyDown(with: try keyEvent(characters: "", keyCode: 124, in: fixture.window))
        XCTAssertEqual(
            fixture.textView.selectedRange(),
            EditableHexTextView.characterRange(forOffset: 19, bytesPerRow: HexRowLayout.bytesPerRow)
        )
    }

    func testFocusedHostRerenderPreservesAuthoritativeCellSelection() throws {
        var bytes: [UInt8] = Array(0..<32)
        let mappings = [
            FileAddressMapping(fileOffset: 0, size: UInt64(bytes.count), virtualAddress: 0x1000)
        ]
        let fixture = try makeFixture(bytes: bytes, mappings: mappings, editable: true)
        var edits: [(offset: Int, byte: UInt8)] = []
        fixture.textView.onByteEdit = { offset, byte in
            edits.append((offset, byte))
            return true
        }

        try clickByte(offset: 18, in: fixture)
        fixture.textView.keyDown(
            with: try keyEvent(characters: "A", keyCode: 0, in: fixture.window)
        )
        XCTAssertTrue(edits.isEmpty)
        fixture.scrollView.render(
            model: HexEditModel(bytes: bytes, mappings: mappings),
            editable: true
        )
        XCTAssertEqual(
            fixture.textView.selectedRange(),
            EditableHexTextView.characterRange(forOffset: 18, bytesPerRow: HexRowLayout.bytesPerRow)
        )

        fixture.textView.keyDown(
            with: try keyEvent(characters: "5", keyCode: 23, in: fixture.window)
        )
        XCTAssertEqual(edits.last?.offset, 18)
        XCTAssertEqual(edits.last?.byte, 0xA5)
        bytes[18] = 0xA5
        fixture.scrollView.render(
            model: HexEditModel(bytes: bytes, mappings: mappings),
            editable: true
        )
        XCTAssertEqual(
            fixture.textView.selectedRange(),
            EditableHexTextView.characterRange(forOffset: 19, bytesPerRow: HexRowLayout.bytesPerRow)
        )
        XCTAssertEqual(
            fixture.textView.accessibilityLabel(),
            "Byte at 0x1013, value 0x13"
        )
    }

    func testFocusReentryResnapsAuthoritativeCellAfterUnfocusedRerender() throws {
        let bytes: [UInt8] = Array(0..<32)
        let mappings = [
            FileAddressMapping(fileOffset: 0, size: UInt64(bytes.count), virtualAddress: 0x1000)
        ]
        let fixture = try makeFixture(bytes: bytes, mappings: mappings, editable: true)
        var editedOffsets: [Int] = []
        fixture.textView.onByteEdit = { offset, _ in
            editedOffsets.append(offset)
            return true
        }

        try clickByte(offset: 18, in: fixture)
        XCTAssertTrue(fixture.window.firstResponder === fixture.textView)
        XCTAssertTrue(fixture.window.makeFirstResponder(nil))
        XCTAssertFalse(fixture.window.firstResponder === fixture.textView)

        fixture.scrollView.render(
            model: HexEditModel(bytes: bytes, mappings: mappings),
            editable: true
        )
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        XCTAssertEqual(
            fixture.textView.selectedRange(),
            EditableHexTextView.characterRange(forOffset: 18, bytesPerRow: HexRowLayout.bytesPerRow)
        )
        XCTAssertEqual(
            fixture.textView.accessibilityLabel(),
            "Byte at 0x1012, value 0x12"
        )

        fixture.textView.keyDown(
            with: try keyEvent(characters: "F", keyCode: 3, in: fixture.window)
        )
        fixture.textView.keyDown(with: try keyEvent(characters: "F", keyCode: 3, in: fixture.window))
        XCTAssertEqual(editedOffsets, [18])
    }

    func testUnfocusedScrolledClickResolvesBeforeFocusRestoresOldCaret() throws {
        let bytes = [UInt8](repeating: 0xAA, count: 1_024)
        let fixture = try makeFixture(bytes: bytes, editable: true)
        var editedOffsets: [Int] = []
        fixture.textView.onByteEdit = { offset, _ in
            editedOffsets.append(offset)
            return true
        }

        try clickByte(offset: 0, in: fixture)
        XCTAssertTrue(fixture.window.makeFirstResponder(nil))

        let targetOffset = 16 * 40 + 2
        let targetRange = try XCTUnwrap(
            EditableHexTextView.characterRange(
                forOffset: targetOffset,
                bytesPerRow: HexRowLayout.bytesPerRow
            )
        )
        fixture.textView.scrollRangeToVisible(targetRange)
        fixture.scrollView.reflectScrolledClipView(fixture.scrollView.contentView)
        XCTAssertGreaterThan(fixture.scrollView.contentView.bounds.origin.y, 0)

        try clickByte(offset: targetOffset, in: fixture)
        XCTAssertEqual(fixture.textView.selectedRange(), targetRange)
        fixture.textView.keyDown(
            with: try keyEvent(characters: "F", keyCode: 3, in: fixture.window)
        )
        fixture.textView.keyDown(with: try keyEvent(characters: "F", keyCode: 3, in: fixture.window))
        XCTAssertEqual(editedOffsets, [targetOffset])
    }

    func testEditableClickResetsPendingLowNibble() throws {
        let fixture = try makeFixture(bytes: [0xAB], editable: true)
        var edits: [(offset: Int, byte: UInt8)] = []
        fixture.textView.onByteEdit = { offset, byte in
            edits.append((offset, byte))
            return true
        }

        fixture.textView.keyDown(with: try keyEvent(characters: "1", keyCode: 18, in: fixture.window))
        try clickByte(offset: 0, in: fixture)
        fixture.textView.keyDown(with: try keyEvent(characters: "2", keyCode: 19, in: fixture.window))
        XCTAssertTrue(edits.isEmpty)
        fixture.textView.keyDown(with: try keyEvent(characters: "B", keyCode: 11, in: fixture.window))
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits[0].offset, 0)
        XCTAssertEqual(edits[0].byte, 0x2B)
    }

    func testInvalidEditableClickResnapsAuthoritativeCell() throws {
        let fixture = try makeFixture(bytes: Array(0..<16), editable: true)
        var editedOffsets: [Int] = []
        fixture.textView.onByteEdit = { offset, _ in
            editedOffsets.append(offset)
            return true
        }

        try clickByte(offset: 5, in: fixture)
        fixture.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let addressPoint = try point(forCharacterIndex: 0, in: fixture.textView)
        try click(point: addressPoint, in: fixture)

        XCTAssertEqual(
            fixture.textView.selectedRange(),
            EditableHexTextView.characterRange(forOffset: 5, bytesPerRow: HexRowLayout.bytesPerRow)
        )
        fixture.textView.keyDown(with: try keyEvent(characters: "F", keyCode: 3, in: fixture.window))
        fixture.textView.keyDown(with: try keyEvent(characters: "F", keyCode: 3, in: fixture.window))
        XCTAssertEqual(editedOffsets, [5])
    }

    func testClickedUnmappedCellRemainsFailClosed() throws {
        let bytes: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD]
        let mappings = [FileAddressMapping(fileOffset: 0, size: 2, virtualAddress: 0x2000)]
        let fixture = try makeFixture(bytes: bytes, mappings: mappings, editable: true)
        var editCount = 0
        fixture.textView.onByteEdit = { _, _ in
            editCount += 1
            return true
        }

        try clickByte(offset: 3, in: fixture)
        fixture.textView.keyDown(with: try keyEvent(characters: "F", keyCode: 3, in: fixture.window))

        XCTAssertEqual(editCount, 0)
        XCTAssertEqual(
            fixture.textView.selectedRange(),
            EditableHexTextView.characterRange(forOffset: 3, bytesPerRow: HexRowLayout.bytesPerRow)
        )
    }

    func testReadOnlyRenderDoesNotAcceptEditingResponderOrMutateText() throws {
        let fixture = try makeFixture(bytes: Array(0..<16), editable: false)
        var editCount = 0
        fixture.textView.onByteEdit = { _, _ in
            editCount += 1
            return true
        }

        XCTAssertFalse(fixture.textView.acceptsFirstResponder)
        fixture.textView.keyDown(
            with: try keyEvent(characters: "F", keyCode: 3, in: fixture.window)
        )
        XCTAssertEqual(editCount, 0)
        XCTAssertEqual(fixture.textView.string, EditableHexTextView.renderLines(bytes: Array(0..<16), baseOffset: 0))
    }

    @MainActor
    private struct Fixture {
        let window: NSWindow
        let scrollView: HexTextScrollView
        var textView: EditableHexTextView { scrollView.textView }
    }

    private func makeFixture(
        bytes: [UInt8],
        mappings: [FileAddressMapping]? = nil,
        editable: Bool
    ) throws -> Fixture {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let scrollView = HexTextScrollView(frame: frame)
        window.contentView = scrollView
        scrollView.textView.frame = frame
        let resolvedMappings = mappings ?? [
            FileAddressMapping(fileOffset: 0, size: UInt64(bytes.count), virtualAddress: 0x1000)
        ]
        scrollView.render(
            model: HexEditModel(bytes: bytes, mappings: resolvedMappings),
            editable: editable
        )
        scrollView.layoutSubtreeIfNeeded()
        if let layoutManager = scrollView.textView.layoutManager,
           let textContainer = scrollView.textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
        } else {
            XCTFail("production hex view must have a TextKit layout manager and container")
        }
        return Fixture(window: window, scrollView: scrollView)
    }

    private func point(forByteOffset offset: Int, in textView: EditableHexTextView) throws -> NSPoint {
        let range = try XCTUnwrap(
            EditableHexTextView.characterRange(forOffset: offset, bytesPerRow: HexRowLayout.bytesPerRow)
        )
        return try point(forCharacterIndex: range.location, in: textView)
    }

    private func point(forCharacterIndex index: Int, in textView: EditableHexTextView) throws -> NSPoint {
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: index, length: 1),
            actualCharacterRange: nil
        )
        XCTAssertEqual(glyphRange.length, 1)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let origin = textView.textContainerOrigin
        return NSPoint(x: rect.midX + origin.x, y: rect.midY + origin.y)
    }

    private func clickByte(offset: Int, in fixture: Fixture) throws {
        try click(point: point(forByteOffset: offset, in: fixture.textView), in: fixture)
    }

    private func click(point: NSPoint, in fixture: Fixture) throws {
        let windowPoint = fixture.textView.convert(point, to: nil)
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: windowPoint,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: fixture.window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )
        fixture.textView.mouseDown(with: event)
    }

    private func keyEvent(
        characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }
}

/// Tests that drive the editable hex pane through the real `WorkspaceStore` patch seam: an edit
/// produces the right `BytePatch` at the right address, is undoable, and the displayed window
/// reflects the patch.
@MainActor
final class HexEditStoreTests: XCTestCase {
    func testHexByteEditsPreserveSurroundingMultiBytePatchAndUndo() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let base: UInt64 = 0x1_0000_0000
        XCTAssertTrue(store.setPatch(base, BytePatch(bytes: [0x1f, 0x20, 0x03, 0xd5])))
        XCTAssertTrue(store.patchByte(at: base, value: 0xaa))
        XCTAssertEqual(store.snapshot.patch(at: base)?.bytes, [0xaa, 0x20, 0x03, 0xd5])
        XCTAssertTrue(store.patchByte(at: base + 1, value: 0xbb))
        XCTAssertEqual(store.snapshot.patch(at: base)?.bytes, [0xaa, 0xbb, 0x03, 0xd5])
        XCTAssertEqual(store.snapshot.patches(in: .primary).count, 1)
        XCTAssertEqual(Array(store.patchedHexWindow().bytes.prefix(4)), [0xaa, 0xbb, 0x03, 0xd5])
        store.undoManager.undo()
        XCTAssertEqual(store.snapshot.patch(at: base)?.bytes, [0xaa, 0x20, 0x03, 0xd5])
    }

    func testHexByteEditUpdatesWinningOverlappingPatchWithoutTruncation() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let base: UInt64 = 0x1_0000_0000
        XCTAssertTrue(store.setPatch(base, BytePatch(bytes: [0xaa, 0xbb, 0xcc, 0xdd])))
        XCTAssertTrue(store.setPatch(base + 1, BytePatch(bytes: [0x11, 0x22])))
        XCTAssertTrue(store.patchByte(at: base + 1, value: 0x99))
        XCTAssertEqual(store.snapshot.patch(at: base)?.bytes, [0xaa, 0xbb, 0xcc, 0xdd])
        XCTAssertEqual(store.snapshot.patch(at: base + 1)?.bytes, [0x99, 0x22])
        XCTAssertEqual(Array(store.patchedHexWindow().bytes.prefix(4)), [0xaa, 0x99, 0x22, 0xdd])
    }

    /// The preview fixture's first instruction is at 0x1_0000_0000 and its bytes are
    /// "ff 83 00 d1", so hexBytes[0] == 0xff (window offset 0 → that address).
    func testApplyHexEditCreatesBytePatchAtCorrectAddress() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        XCTAssertNil(store.snapshot.patch(at: 0x1_0000_0000))

        XCTAssertTrue(store.applyHexEdit(offset: 0, hexByte: "90"))

        let patch = store.snapshot.patch(at: 0x1_0000_0000)
        XCTAssertEqual(patch, BytePatch(bytes: [0x90]))
    }

    func testApplyHexByteEditMapsOffsetToAddress() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        // Offset 4 → second instruction's first byte → address 0x1_0000_0004.
        XCTAssertTrue(store.applyHexByteEdit(offset: 4, value: 0xcc))
        XCTAssertEqual(store.snapshot.patch(at: 0x1_0000_0004), BytePatch(bytes: [0xcc]))
        // The byte at offset 0 stays unpatched.
        XCTAssertNil(store.snapshot.patch(at: 0x1_0000_0000))
    }

    func testHexEditIsUndoable() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        store.applyHexEdit(offset: 0, hexByte: "90")
        XCTAssertNotNil(store.snapshot.patch(at: 0x1_0000_0000))

        store.undoManager.undo()
        XCTAssertNil(store.snapshot.patch(at: 0x1_0000_0000))

        store.undoManager.redo()
        XCTAssertEqual(store.snapshot.patch(at: 0x1_0000_0000), BytePatch(bytes: [0x90]))
    }

    func testInvalidHexEditChangesNothingAndSurfacesIssue() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        XCTAssertFalse(store.applyHexEdit(offset: 0, hexByte: "zz"))
        XCTAssertNil(store.snapshot.patch(at: 0x1_0000_0000))
        XCTAssertNotNil(store.lastIssue)
    }

    func testOutOfRangeEditChangesNothing() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let farOffset = store.snapshot.hexBytes.count + 100
        XCTAssertFalse(store.applyHexByteEdit(offset: farOffset, value: 0x90))
        XCTAssertTrue(store.snapshot.patches(in: .primary).isEmpty)
    }

    func testPatchedHexWindowOverlaysEditedByteAndFlagsOffset() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        XCTAssertEqual(store.snapshot.hexBytes.first, 0xff) // fixture sanity

        store.applyHexByteEdit(offset: 0, value: 0x90)
        let window = store.patchedHexWindow()
        XCTAssertEqual(window.bytes.first, 0x90)            // displayed value reflects the edit
        XCTAssertTrue(window.patchedOffsets.contains(0))    // and the offset is flagged for highlight
        XCTAssertFalse(window.patchedOffsets.contains(1))
    }

    func testPatchedHexWindowUnchangedWithoutPatches() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let window = store.patchedHexWindow()
        XCTAssertEqual(window.bytes, store.snapshot.hexBytes)
        XCTAssertTrue(window.patchedOffsets.isEmpty)
    }

    func testReEditingACellReplacesThePatchValue() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        store.applyHexByteEdit(offset: 0, value: 0x90)
        XCTAssertEqual(store.snapshot.patch(at: 0x1_0000_0000), BytePatch(bytes: [0x90]))

        // Editing the same cell again replaces the value (no second patch, no append): the patch
        // model is value-based per address, so a re-edit overwrites cleanly.
        store.applyHexByteEdit(offset: 0, value: 0x91)
        XCTAssertEqual(store.snapshot.patch(at: 0x1_0000_0000), BytePatch(bytes: [0x91]))
        XCTAssertEqual(store.snapshot.patches(in: .primary).count, 1)
    }
}
