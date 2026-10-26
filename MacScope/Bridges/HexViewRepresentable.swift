import AppKit
import SwiftUI
import LumenUI

/// The fixed geometry of a rendered hex row, shared by the renderer and the caret↔offset
/// mapping so the two never drift. A row is:
///   `OOOOOOOO␠␠HH␠HH␠…␠HH␠␠|ascii|`
/// `addressColumns` is the `%08X` offset + the two spaces before the first hex pair; each hex
/// cell is two digits + a trailing space (`hexCellStride`). The ASCII gutter is display-only.
enum HexRowLayout {
    static let bytesPerRow = 16
    static let addressColumns = 8 + 2          // "%08X" + "  "
    static let hexCellStride = 3               // "HH "
}

/// An `NSTextView` that renders the hex window and accepts in-place hex edits. Typing a hex
/// pair over a byte reports one complete replacement byte (and its
/// window offset) through `onByteEdit`; the SwiftUI layer routes that to
/// `WorkspaceStore.applyHexEdit`, which writes an undoable `BytePatch`. Non-hex keys are
/// swallowed (rejected) rather than inserted, so the buffer can never hold garbage. Arrow keys
/// move the caret between byte cells. When `isEditable` is false (no document) it behaves like
/// the original read-only viewer.
final class EditableHexTextView: NSTextView {
    /// Reports a committed byte edit: the window byte offset and the new value. The host applies
    /// it as a patch and re-renders. Returns true when the edit was accepted (applied).
    var onByteEdit: ((_ offset: Int, _ value: UInt8) -> Bool)?
    /// Publishes a user-originated mapped caret. The host rechecks captured pane authority.
    var onCaretMove: ((_ offset: Int, _ target: ImageAddress) -> Bool)?

    /// The model backing the current render, used for caret↔offset mapping, nibble composition,
    /// and accessibility. Replaced on every render.
    private(set) var model = HexEditModel(bytes: Data(), mappings: [])

    /// The byte offset under the caret. Drives which cell a typed nibble edits and which nibble
    /// (high on first keystroke into a cell, low on the second).
    private var caretOffset = 0
    /// True once the high nibble of the current cell has been typed, so the next digit fills the
    /// low nibble and advances. Reset whenever the caret moves cells.
    private var awaitingLowNibble = false
    private var pendingHighNibble: UInt8?
    private var presentedSelection: ImageAddress?
    private var presentedImageSlot: ImageSlot?
    private var presentedOwnerBinaryID: UUID?
    private var hasAuthoritativeCaret = true
    private var renderRevision: UInt64 = 0
    private var lastPatternRevealToken: UUID?
    private var hasPatternStyling = false
    var onPatternRevealScroll: ((NSRange) -> Void)?

    /// Renders `bytes` (already patch-overlaid by the host) and refreshes the editing model.
    /// `editable` gates whether keystrokes mutate anything.
    func render(model: HexEditModel, editable: Bool, selection: ImageAddress? = nil,
                imageSlot: ImageSlot = .primary, ownerBinaryID: UUID? = nil,
                patchedOffsets: Set<Int> = [], displayOffset: Int = 0,
                patternReveal: PatternRevealCommand? = nil, patternRecordPreview: Range<Int>? = nil) {
        renderRevision &+= 1
        let shouldRestoreFocusedCell = editable && window?.firstResponder === self
        let patternSelection = hasPatternStyling || patternReveal != nil || patternRecordPreview != nil
            ? selectedRange() : nil
        let authorityChanged = ownerBinaryID != presentedOwnerBinaryID
            || model.mappings != self.model.mappings
            || model.windowFileOffset != self.model.windowFileOffset
            || model.byteCount != self.model.byteCount
        // Publishing a caret causes the store to echo that same cell back through SwiftUI.
        // This is presentation acknowledgement, not a new navigation intent or nibble reset.
        let sameCaretEcho = !authorityChanged && imageSlot == presentedImageSlot
            && hasAuthoritativeCaret && selection != nil
            && selection == model.address(forOffset: caretOffset).map {
                ImageAddress(slot: imageSlot, address: $0)
            }
        self.model = model
        isEditable = false           // we intercept keyDown ourselves; never free-type into the buffer
        isSelectable = true
        // Row labels show slice offsets: the window (MS-10) starts at `displayOffset`.
        let lines = Self.renderLines(bytes: model.bytes, baseOffset: displayOffset)
        string = lines
        if hasPatternStyling, let storage = textStorage {
            let full = NSRange(location: 0, length: storage.length)
            storage.removeAttribute(.underlineStyle, range: full)
            storage.removeAttribute(.underlineColor, range: full)
            hasPatternStyling = false
        }
        applyHexStyle(bytes: model.bytes)
        for offset in patchedOffsets {
            guard let range = Self.characterRange(forOffset: offset, bytesPerRow: HexRowLayout.bytesPerRow),
                  NSMaxRange(range) <= (string as NSString).length else { continue }
            textStorage?.addAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.25), range: range)
        }
        let selectionChanged = authorityChanged || selection != presentedSelection || imageSlot != presentedImageSlot
        presentedSelection = selection
        presentedImageSlot = imageSlot
        presentedOwnerBinaryID = ownerBinaryID
        if selectionChanged && !sameCaretEcho {
            awaitingLowNibble = false
            pendingHighNibble = nil
            if let selection, selection.slot == imageSlot,
               let offset = model.offset(forAddress: selection.address) {
                caretOffset = offset
                hasAuthoritativeCaret = true
            } else {
                caretOffset = 0
                hasAuthoritativeCaret = selection == nil
            }
        }
        // Keep the caret offset in range across re-renders.
        if let clamped = model.clamped(caretOffset) { caretOffset = clamped } else { caretOffset = 0 }
        canEdit = editable
        if shouldRestoreFocusedCell || selectionChanged {
            // Replacing `string` clears NSTextView's native selection. A host-applied byte patch
            // re-renders immediately after keyDown, so restore the focused authoritative cell
            // instead of leaving the visible insertion point detached from `caretOffset`.
            selectCaretCell()
        } else if let patternSelection, NSMaxRange(patternSelection) <= (string as NSString).length {
            // Applying or clearing display-only pattern styling must also preserve an
            // unfocused native selection when replacing the rendered text.
            setSelectedRange(patternSelection)
        }
        applyPatternPreview(patternRecordPreview)
        applyPatternReveal(patternReveal)
        refreshAccessibility()
    }

    private func admittedPatternCells(_ range: Range<Int>) -> [NSRange]? {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= model.byteCount else { return nil }
        var cells: [NSRange] = []
        for offset in range {
            guard let cell = Self.characterRange(forOffset: offset, bytesPerRow: HexRowLayout.bytesPerRow),
                  NSMaxRange(cell) <= (string as NSString).length else { return nil }
            cells.append(cell)
        }
        return cells
    }

    private func applyPatternPreview(_ range: Range<Int>?) {
        guard let range, let cells = admittedPatternCells(range) else { return }
        hasPatternStyling = true
        for cell in cells {
            textStorage?.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: cell)
            textStorage?.addAttribute(.underlineColor, value: NSColor.secondaryLabelColor, range: cell)
        }
    }

    private func applyPatternReveal(_ command: PatternRevealCommand?) {
        guard let command, let cells = admittedPatternCells(command.range), let first = cells.first else {
            lastPatternRevealToken = nil
            return
        }
        hasPatternStyling = true
        for cell in cells {
            textStorage?.addAttribute(.underlineStyle, value: NSUnderlineStyle.double.rawValue, range: cell)
            textStorage?.addAttribute(.underlineColor, value: NSColor.systemTeal, range: cell)
        }
        if lastPatternRevealToken != command.token {
            onPatternRevealScroll?(first)
            scrollRangeToVisible(first)
            lastPatternRevealToken = command.token
        }
    }

    /// Whether this view currently accepts edits (a document is loaded and bytes are present).
    private var canEdit = false

    override var acceptsFirstResponder: Bool { canEdit }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder, canEdit {
            // Keyboard focus can return after an unfocused host re-render cleared NSTextView's
            // native selection. Re-derive presentation from the authoritative mutation offset
            // before this responder can receive a key event.
            selectCaretCell()
            refreshAccessibility()
        }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        awaitingLowNibble = false
        pendingHighNibble = nil
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        guard canEdit else {
            super.mouseDown(with: event)
            return
        }

        // Editable clicks are cell selections, not arbitrary NSTextView selections. Keep the
        // native selection and the authoritative mutation offset synchronized, and fail closed
        // if this view cannot become the responder that will receive the subsequent key event.
        guard let window else { return }
        // Capture the hit against the viewport the user actually clicked. Becoming first
        // responder can scroll the old authoritative caret into view, which must not retarget
        // this window-space event before it is resolved.
        let viewPoint = convert(event.locationInWindow, from: nil)
        let clickedOffset = byteOffset(atViewPoint: viewPoint)
        if window.firstResponder !== self {
            guard validateProposedFirstResponder(self, for: event),
                  window.makeFirstResponder(self) else { return }
        }

        guard let offset = clickedOffset else {
            // Address text, separators, padding, ASCII, and blank space are not editable cells.
            // Reassert the authoritative cell so native presentation can never drift from the
            // byte that keyDown would mutate.
            selectCaretCell()
            refreshAccessibility()
            return
        }

        let previousOffset = caretOffset
        caretOffset = offset
        hasAuthoritativeCaret = true
        awaitingLowNibble = false
        pendingHighNibble = nil
        publishUserCaret(previousOffset: previousOffset)
        selectCaretCell()
        refreshAccessibility()
    }

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        guard canEdit else { super.keyDown(with: event); return }

        // Command/control/option chords are not hex text. In particular,
        // charactersIgnoringModifiers turns Command-1 into a valid nibble; never
        // let an unhandled shortcut mutate bytes or advance our nibble state.
        // Keep normal AppKit handling instead of redispatching through the menu.
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 48:
            awaitingLowNibble = false
            pendingHighNibble = nil
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
            return
        case 53:
            awaitingLowNibble = false
            pendingHighNibble = nil
            return
        case 36, 76:
            awaitingLowNibble = false
            pendingHighNibble = nil
            window?.selectNextKeyView(self)
            return
        case 115, 119, 116, 121:
            guard hasAuthoritativeCaret else { return }
            let pageRows = max(1, Int(visibleRect.height / max(1, (font?.pointSize ?? 12) * 1.3)))
            let previousOffset = caretOffset
            let candidate: Int
            switch event.keyCode {
            case 115: candidate = 0
            case 119: candidate = model.byteCount - 1
            case 116: candidate = caretOffset - pageRows * HexRowLayout.bytesPerRow
            default: candidate = caretOffset + pageRows * HexRowLayout.bytesPerRow
            }
            if let offset = model.clamped(candidate) { caretOffset = offset }
            awaitingLowNibble = false
            pendingHighNibble = nil
            publishUserCaret(previousOffset: previousOffset)
            selectCaretCell()
            refreshAccessibility()
            return
        case 123: moveCaret(.left); return     // left arrow
        case 124: moveCaret(.right); return    // right arrow
        case 126: moveCaret(.up); return       // up arrow
        case 125: moveCaret(.down); return     // down arrow
        default: break
        }

        // A single hex digit edits the nibble under the caret; everything else is rejected
        // (swallowed) so the buffer stays a faithful render of the bytes.
        guard let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              let digit = characters.first,
              digit.isHexDigit else {
            NSSound.beep()
            return
        }

        guard hasAuthoritativeCaret, model.address(forOffset: caretOffset) != nil,
              let nibble = digit.hexDigitValue else { NSSound.beep(); return }
        if !awaitingLowNibble {
            pendingHighNibble = UInt8(nibble) << 4
            awaitingLowNibble = true
            return
        }
        let composed = (pendingHighNibble ?? 0) | UInt8(nibble)
        switch model.resolveEdit(offset: caretOffset, hexByte: String(format: "%02x", composed)) {
        case let .patch(_, value):
            let accepted = onByteEdit?(caretOffset, value) ?? false
            if accepted {
                awaitingLowNibble = false
                pendingHighNibble = nil
                moveCaret(.right)
            } else {
                NSSound.beep()
            }
        case .invalidInput, .outOfRange, .readOnly, .unmapped:
            NSSound.beep()
        }
    }

    private func moveCaret(_ direction: HexEditModel.CaretDirection) {
        guard let next = model.offset(movingFrom: caretOffset, direction, bytesPerRow: HexRowLayout.bytesPerRow) else {
            return
        }
        let previousOffset = caretOffset
        if next != caretOffset {
            caretOffset = next
            awaitingLowNibble = false
            pendingHighNibble = nil
        }
        publishUserCaret(previousOffset: previousOffset)
        selectCaretCell()
        refreshAccessibility()
    }

    /// Only event handlers call this method. Rendering and focus restoration never publish.
    private func publishUserCaret(previousOffset: Int) {
        guard hasAuthoritativeCaret, presentedOwnerBinaryID != nil,
              let slot = presentedImageSlot, let address = model.address(forOffset: caretOffset),
              let onCaretMove else { return }
        let target = ImageAddress(slot: slot, address: address)
        guard target != presentedSelection else { return }
        let revision = renderRevision
        let accepted = onCaretMove(caretOffset, target)
        // A synchronous host can replace the rendered authority while handling the callback.
        // Never restore an old offset or acknowledgement into its new render.
        guard renderRevision == revision else { return }
        if accepted { presentedSelection = target }
        else if let offset = model.clamped(previousOffset) { caretOffset = offset }
    }

    /// Selects the two hex digits of the cell under the caret so the edit point is visible and
    /// VoiceOver reads the right cell.
    private func selectCaretCell() {
        guard hasAuthoritativeCaret else { setSelectedRange(NSRange(location: 0, length: 0)); return }
        guard let range = Self.characterRange(forOffset: caretOffset, bytesPerRow: HexRowLayout.bytesPerRow),
              range.location + range.length <= (string as NSString).length else { return }
        setSelectedRange(range)
        scrollRangeToVisible(range)
    }

    private func refreshAccessibility() {
        setAccessibilityLabel(model.accessibilityLabel(forOffset: caretOffset))
    }

    /// Resolves an exact view-space hit to a rendered byte cell. TextKit's glyph hit-test returns
    /// the nearest glyph outside text, so containment in the returned glyph's own bounds is a
    /// required proof before the pure character-index inverse is consulted.
    func byteOffset(atViewPoint point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)

        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        guard layoutManager.isValidGlyphIndex(glyphIndex) else { return nil }

        let glyphRange = NSRange(location: glyphIndex, length: 1)
        let glyphBounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        guard glyphBounds.contains(containerPoint) else { return nil }

        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return Self.byteOffset(
            forCharacterIndex: characterIndex,
            byteCount: model.byteCount,
            bytesPerRow: HexRowLayout.bytesPerRow
        )
    }

    // MARK: - Rendering + geometry (pure, unit-testable)

    /// The character width of one fully-populated rendered row, in characters (only complete
    /// rows precede `offset`'s row, so the partial final row's width never enters the math). The
    /// format is `"%08X  %-47@  |ascii|\n"` for a full 16-byte row:
    ///   8 (`%08X`) + 2 spaces + 47 (the hex column, `16*3 - 1`) + 2 spaces + 1 (`|`)
    ///   + 16 (ascii) + 1 (`|`) + 1 (newline) = 78.
    static func fullRowWidth(bytesPerRow: Int) -> Int {
        let hexColumnWidth = bytesPerRow * HexRowLayout.hexCellStride - 1 // "HH HH … HH"
        return HexRowLayout.addressColumns
            + hexColumnWidth
            + 2          // two spaces before the ASCII gutter
            + 1          // leading "|"
            + bytesPerRow // ascii chars
            + 1          // trailing "|"
            + 1          // newline
    }

    /// The character range of the two hex digits for the byte at `offset` within the rendered
    /// text, or nil when out of range. Derived purely from `HexRowLayout` so a test can assert
    /// the caret lands on the right digits without a live view.
    static func characterRange(forOffset offset: Int, bytesPerRow: Int) -> NSRange? {
        guard offset >= 0, bytesPerRow > 0 else { return nil }
        guard bytesPerRow <= (Int.max - 14) / 4 else { return nil }

        let row = offset / bytesPerRow
        let col = offset % bytesPerRow
        let rowWidth = fullRowWidth(bytesPerRow: bytesPerRow)
        let (rowStart, rowOverflow) = row.multipliedReportingOverflow(by: rowWidth)
        let (columnStart, columnOverflow) = col.multipliedReportingOverflow(
            by: HexRowLayout.hexCellStride
        )
        guard !rowOverflow, !columnOverflow else { return nil }

        let (hexStart, addressOverflow) = rowStart.addingReportingOverflow(
            HexRowLayout.addressColumns
        )
        let (cellStart, cellOverflow) = hexStart.addingReportingOverflow(columnStart)
        let (_, rangeOverflow) = cellStart.addingReportingOverflow(2)
        guard !addressOverflow, !cellOverflow, !rangeOverflow else { return nil }
        return NSRange(location: cellStart, length: 2)
    }

    /// The inverse of `characterRange(forOffset:)`: maps only the two hexadecimal digit
    /// characters of a real byte cell back to its byte offset. Every other rendered character —
    /// including address text, separators, padding, ASCII, gutters, and newlines — returns nil.
    static func byteOffset(
        forCharacterIndex characterIndex: Int,
        byteCount: Int,
        bytesPerRow: Int
    ) -> Int? {
        guard characterIndex >= 0, byteCount > 0, bytesPerRow > 0 else { return nil }

        // A full row is `4 * bytesPerRow + 14` characters for the current fixed layout. Bound
        // the caller-controlled row width before delegating to `fullRowWidth` so malformed test
        // or future inputs cannot overflow Int arithmetic.
        guard bytesPerRow <= (Int.max - 14) / 4 else { return nil }
        let rowWidth = fullRowWidth(bytesPerRow: bytesPerRow)
        let row = characterIndex / rowWidth
        let positionInRow = characterIndex % rowWidth
        let (rowByteStart, rowOverflow) = row.multipliedReportingOverflow(by: bytesPerRow)
        guard !rowOverflow, rowByteStart < byteCount else { return nil }

        guard positionInRow >= HexRowLayout.addressColumns else { return nil }
        let positionInHexColumn = positionInRow - HexRowLayout.addressColumns
        let column = positionInHexColumn / HexRowLayout.hexCellStride
        let positionInCell = positionInHexColumn % HexRowLayout.hexCellStride
        let bytesInRow = min(bytesPerRow, byteCount - rowByteStart)
        guard column < bytesInRow, positionInCell < 2 else { return nil }

        let (offset, offsetOverflow) = rowByteStart.addingReportingOverflow(column)
        guard !offsetOverflow else { return nil }
        return offset
    }

    /// Lumen's quiet hex colors (U2-hex): offsets in the offset color, bytes with zeros faded,
    /// unprintable ASCII and the `|` separators quieter. Positions come from `HexRowLayout`.
    private func applyHexStyle(bytes: [UInt8]) {
        let style = DSHexStyle.current()
        textColor = style.byte
        selectedTextAttributes = [.backgroundColor: style.selectionBackground, .foregroundColor: style.selectionForeground]
        guard let storage = textStorage, !bytes.isEmpty else { return }
        let length = storage.length
        let rowWidth = Self.fullRowWidth(bytesPerRow: HexRowLayout.bytesPerRow)
        let asciiBar = HexRowLayout.addressColumns + HexRowLayout.bytesPerRow * HexRowLayout.hexCellStride - 1 + 2
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.addAttribute(.foregroundColor, value: style.byte, range: NSRange(location: 0, length: length))
        for rowStartByte in stride(from: 0, to: bytes.count, by: HexRowLayout.bytesPerRow) {
            let rowStart = (rowStartByte / HexRowLayout.bytesPerRow) * rowWidth
            let count = min(HexRowLayout.bytesPerRow, bytes.count - rowStartByte)
            guard rowStart + asciiBar + count + 2 <= length + 1 else { break }
            storage.addAttribute(.foregroundColor, value: style.offset, range: NSRange(location: rowStart, length: 8))
            storage.addAttribute(.foregroundColor, value: style.separator, range: NSRange(location: rowStart + asciiBar, length: 1))
            storage.addAttribute(.foregroundColor, value: style.separator,
                                 range: NSRange(location: rowStart + asciiBar + 1 + count, length: 1))
            for column in 0..<count {
                let value = bytes[rowStartByte + column]
                if value == 0 {
                    storage.addAttribute(.foregroundColor, value: style.zeroByte, range: NSRange(
                        location: rowStart + HexRowLayout.addressColumns + column * HexRowLayout.hexCellStride, length: 2))
                }
                if !(value >= 0x20 && value < 0x7f) {
                    storage.addAttribute(.foregroundColor, value: style.unprintable,
                                         range: NSRange(location: rowStart + asciiBar + 1 + column, length: 1))
                }
            }
        }
    }

    /// The hex dump text for `bytes`, identical in shape to the original read-only renderer so
    /// existing layout/geometry expectations hold.
    static func renderLines(bytes: [UInt8], baseOffset: Int) -> String {
        var lines: [String] = []
        for chunkStart in stride(from: 0, to: bytes.count, by: HexRowLayout.bytesPerRow) {
            let chunkEnd = min(chunkStart + HexRowLayout.bytesPerRow, bytes.count)
            let chunk = bytes[chunkStart..<chunkEnd]
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = chunk.map { byte -> String in
                if byte >= 0x20 && byte < 0x7f, let scalar = UnicodeScalar(Int(byte)) {
                    return String(Character(scalar))
                }
                return "."
            }.joined()
            lines.append(String(format: "%08X  %-47@  |%@|", baseOffset + chunkStart, hex as NSString, ascii as NSString))
        }
        return lines.joined(separator: "\n")
    }
}

final class HexTextScrollView: NSScrollView {
    let textView = EditableHexTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = AppTypography.pseudocodeAppKit   // the listing font preference (SF Mono 12 by default)
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.drawsBackground = false
        // The listing's own selection role (editor theme), instead of the default system-blue
        // text selection, so hex and disassembly selections match in every theme.
        textView.selectedTextAttributes = [.backgroundColor: Lumen.nsColor(.listingSelection)]
        textView.insertionPointColor = NSColor(Color.lumen(.accent))

        // Configure the text view as a non-wrapping, both-axes-scrollable document
        // view. Without the resizable flags and an unbounded text container the
        // view collapses to zero size inside the scroll view and renders nothing.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        if let container = textView.textContainer {
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }

        documentView = textView
        hasVerticalScroller = true
        hasHorizontalScroller = true
        drawsBackground = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    func render(model: HexEditModel, editable: Bool) {
        textView.render(model: model, editable: editable)
    }
}

struct HexViewRepresentable: NSViewRepresentable {
    let bytes: Data
    let baseOffset: Int
    /// The slice offset of the window's first byte, for the row labels only (MS-10). Edits,
    /// mappings and callbacks stay window-relative.
    let displayOffset: Int
    /// Read when the parent's body creates this view, which subscribes the parent to theme
    /// changes; updateNSView then re-styles with the new editor palette.
    private let editorThemeID = DSThemeStore.shared.editorTheme.id
    /// The verified file-offset → virtual-address mappings for the displayed payload window.
    /// Empty => every cell is unmapped and the pane is read-only.
    let mappings: [FileAddressMapping]
    let isEditable: Bool
    let selection: ImageAddress?
    let imageSlot: ImageSlot
    let ownerBinaryID: UUID?
    let patchedOffsets: Set<Int>
    let patternReveal: PatternRevealCommand?
    let patternRecordPreview: Range<Int>?
    /// Applies a committed byte edit; returns true when accepted. nil = read-only.
    let onByteEdit: ((_ offset: Int, _ value: UInt8) -> Bool)?
    let onCaretMove: ((_ offset: Int, _ target: ImageAddress) -> Bool)?

    init(
        bytes: Data,
        baseOffset: Int,
        mappings: [FileAddressMapping] = [],
        isEditable: Bool = false,
        selection: ImageAddress? = nil,
        imageSlot: ImageSlot = .primary,
        ownerBinaryID: UUID? = nil,
        patchedOffsets: Set<Int> = [],
        onByteEdit: ((_ offset: Int, _ value: UInt8) -> Bool)? = nil,
        onCaretMove: ((_ offset: Int, _ target: ImageAddress) -> Bool)? = nil,
        displayOffset: Int = 0,
        patternReveal: PatternRevealCommand? = nil,
        patternRecordPreview: Range<Int>? = nil
    ) {
        self.bytes = bytes
        self.baseOffset = baseOffset
        self.displayOffset = displayOffset
        self.mappings = mappings
        self.isEditable = isEditable
        self.selection = selection
        self.imageSlot = imageSlot
        self.ownerBinaryID = ownerBinaryID
        self.patchedOffsets = patchedOffsets
        self.patternReveal = patternReveal
        self.patternRecordPreview = patternRecordPreview
        self.onByteEdit = onByteEdit
        self.onCaretMove = onCaretMove
    }

    private var model: HexEditModel {
        HexEditModel(bytes: bytes, mappings: mappings, windowFileOffset: UInt64(max(0, baseOffset)))
    }

    func makeNSView(context: Context) -> HexTextScrollView {
        let view = HexTextScrollView()
        view.textView.onByteEdit = onByteEdit
        view.textView.onCaretMove = onCaretMove
        view.textView.render(model: model, editable: isEditable, selection: selection,
                             imageSlot: imageSlot, ownerBinaryID: ownerBinaryID, patchedOffsets: patchedOffsets,
                             displayOffset: displayOffset, patternReveal: patternReveal,
                             patternRecordPreview: patternRecordPreview)
        return view
    }

    func updateNSView(_ nsView: HexTextScrollView, context: Context) {
        nsView.textView.onByteEdit = onByteEdit
        nsView.textView.onCaretMove = onCaretMove
        nsView.textView.render(model: model, editable: isEditable, selection: selection,
                               imageSlot: imageSlot, ownerBinaryID: ownerBinaryID, patchedOffsets: patchedOffsets,
                             displayOffset: displayOffset, patternReveal: patternReveal,
                             patternRecordPreview: patternRecordPreview)
    }
}
